import Foundation
import JavaScriptCore
import os

// MARK: - BotGuardError

public enum BotGuardError: Error, CustomStringConvertible {
    case challengeFailed(String)
    case challengeParseError(String)
    case jsFailed(String)
    case integrityTokenFailed(String)
    case mintFailed(String)

    public var description: String {
        switch self {
        case .challengeFailed(let m):       "BotGuard challenge fetch failed: \(m)"
        case .challengeParseError(let m):   "BotGuard challenge parse error: \(m)"
        case .jsFailed(let m):              "BotGuard JS error: \(m)"
        case .integrityTokenFailed(let m):  "BotGuard integrity token failed: \(m)"
        case .mintFailed(let m):            "BotGuard mint failed: \(m)"
        }
    }
}

// MARK: - BotGuardClient

/// Generates YouTube Proof-of-Origin (PO) tokens on-device using JavaScriptCore.
///
/// The BotGuard attestation pipeline mirrors https://github.com/LuanRT/BgUtils (MIT):
/// 1. Fetch the BotGuard challenge (interpreter JS + program + globalName) from Google's WAA API.
/// 2. Execute the interpreter JS in a `JSContext`; call `vm.a(program, callback, …)` to load the program.
/// 3. Call `asyncSnapshotFn(callback, params)` → `botguardResponse` string.
/// 4. POST `botguardResponse` to WAA GenerateIT → `integrityTokenB64`.
/// 5. Call `webPoSignalOutput[0](integrityTokenBytes)` → minter → call minter with videoId bytes → base64 token.
///
/// All JSContext work and blocking network calls run on a dedicated serial `jsQueue` (a real OS thread).
/// Network calls use `URLSession.dataTask` + `DispatchSemaphore` — safe because `jsQueue` is not part of
/// Swift's cooperative concurrency thread pool.
public final class BotGuardClient: PoTokenProvider, @unchecked Sendable {

    // MARK: - WAA API constants
    // Public API key used by YouTube's web client; from BgUtils / YouTube JS source.
    private static let waaAPIKey  = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    // YouTube BotGuard request key (stable; from BgUtils examples).
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    private static let waaCreateURL     = URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/Create")!
    private static let waaGenerateITURL = URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/GenerateIT")!

    // MARK: - Properties
    private let session: URLSession
    private let bgLog = Logger(subsystem: appSubsystem, category: "BotGuard")
    /// All JSContext access serialised on this queue. It is a real OS thread, so
    /// `DispatchSemaphore.wait()` inside blocks here does NOT block the Swift cooperative pool.
    private let jsQueue = DispatchQueue(label: "st.botguard.js", qos: .userInitiated)

    // MARK: - Init

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - PoTokenProvider

    public func token(for videoId: String) async throws -> String {
        bgLog.notice("[BotGuard] token requested for \(videoId, privacy: .public)")

        // Phase 1 – fetch challenge (async Swift network call, off jsQueue).
        let challenge = try await fetchChallenge()
        bgLog.notice("[BotGuard] challenge ok, globalName=\(challenge.globalName, privacy: .public) jsLen=\(challenge.interpreterJS.count)")

        // Phase 2–5 – run entirely on jsQueue to keep all JSValue references on one thread.
        let token = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            jsQueue.async {
                do {
                    let tok = try self.runPipelineSync(challenge: challenge, videoId: videoId)
                    cont.resume(returning: tok)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        bgLog.notice("[BotGuard] ✅ PO token minted (len=\(token.count)) for \(videoId, privacy: .public)")
        return token
    }

    // MARK: - Challenge model

    private struct BotGuardChallenge {
        let interpreterJS: String
        let program: String
        let globalName: String
    }

    // MARK: - Phase 1: fetch challenge from WAA Create endpoint

    private func fetchChallenge() async throws -> BotGuardChallenge {
        var req = URLRequest(url: Self.waaCreateURL, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.waaAPIKey,              forHTTPHeaderField: "x-goog-api-key")
        req.setValue("grpc-web-javascript/0.1",   forHTTPHeaderField: "x-user-agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: [Self.requestKey])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BotGuardError.challengeFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        // Response: [requestKey, [messageId?, interpreterHash, interpreterURL_or_JS, program, globalName, ...]]
        // Some YouTube builds wrap the inner array an additional level: [requestKey, [[...]]]
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [Any],
              outer.count >= 2 else {
            throw BotGuardError.challengeParseError("outer array missing")
        }
        let inner: [Any]
        if let directInner = outer[1] as? [Any] {
            inner = directInner
        } else if let nestedOuter = outer[1] as? [[Any]], let first = nestedOuter.first {
            inner = first
        } else {
            throw BotGuardError.challengeParseError("inner array missing at outer[1]")
        }

        // inner layout (BgUtils parseChallengeData):
        // [0] = messageId (optional string)
        // [1] = interpreterHash (string)
        // [2] = interpreter URL (// prefixed) or inline JS (string)
        // [3] = program (string – BotGuard bytecode)
        // [4] = globalName (string – VM identifier in the interpreter global scope)
        guard inner.count >= 5 else {
            throw BotGuardError.challengeParseError("inner array too short (\(inner.count))")
        }

        var interpreterJS = ""
        if let raw = inner[2] as? String, !raw.isEmpty {
            let urlStr = raw.hasPrefix("//") ? "https:\(raw)" : raw
            if let jsURL = URL(string: urlStr), jsURL.scheme != nil, jsURL.host != nil {
                // Fetch interpreter script from URL
                let (jsData, _) = try await session.data(from: jsURL)
                interpreterJS = String(data: jsData, encoding: .utf8) ?? ""
                bgLog.notice("[BotGuard] interpreter JS fetched from URL (len=\(interpreterJS.count))")
            } else {
                interpreterJS = raw
            }
        }

        guard !interpreterJS.isEmpty else {
            throw BotGuardError.challengeParseError("interpreter JS empty")
        }
        guard let program = inner[3] as? String, !program.isEmpty else {
            throw BotGuardError.challengeParseError("program empty")
        }
        guard let globalName = inner[4] as? String, !globalName.isEmpty else {
            throw BotGuardError.challengeParseError("globalName empty")
        }

        return BotGuardChallenge(interpreterJS: interpreterJS, program: program, globalName: globalName)
    }

    // MARK: - Phase 2–5: synchronous pipeline on jsQueue

    /// Runs the entire BotGuard pipeline synchronously:
    /// JS VM execution → integrity token fetch (blocking) → mint (JS).
    /// Must be called from `jsQueue` only.
    private func runPipelineSync(challenge: BotGuardChallenge, videoId: String) throws -> String {

        // --- Set up JSContext with minimal polyfills ---
        guard let ctx = JSContext() else {
            throw BotGuardError.jsFailed("JSContext() returned nil")
        }
        ctx.exceptionHandler = { [weak self] _, exc in
            self?.bgLog.warning("[BotGuard] JSContext exception: \(exc?.toString() ?? "nil", privacy: .public)")
        }
        installPolyfills(ctx)

        // --- Load BotGuard interpreter VM ---
        ctx.evaluateScript(challenge.interpreterJS)
        if let exc = ctx.exception {
            throw BotGuardError.jsFailed("interpreter load: \(exc)")
        }

        // --- Locate the VM object in global scope ---
        guard let vm = ctx.globalObject?.objectForKeyedSubscript(challenge.globalName),
              !vm.isNull, !vm.isUndefined else {
            throw BotGuardError.jsFailed("VM '\(challenge.globalName)' not in JSContext global")
        }

        // --- Phase 2: call vm.a(program, vmFunctionsCallback, true, undefined, noop, [[], []]) ---
        var asyncSnapshotFn: JSValue?
        let vmFnCallback: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> Void = { fn, _, _, _ in
            asyncSnapshotFn = fn
        }
        let undef    = JSValue(undefinedIn: ctx)!
        let noopFn   = JSValue(object: { } as @convention(block) () -> Void, in: ctx)!
        let initPair = ctx.evaluateScript("[[],[]]")!

        let vmCallResult = vm.objectForKeyedSubscript("a")?.call(withArguments: [
            challenge.program,
            JSValue(object: vmFnCallback, in: ctx)!,
            NSNumber(value: true),
            undef,
            noopFn,
            initPair
        ])

        if let exc = ctx.exception { throw BotGuardError.jsFailed("vm.a(): \(exc)") }

        // vm.a() may return [syncFn, ...] or [Promise, ...]; pump microtasks either way.
        if let initPromise = vmCallResult?.objectAtIndexedSubscript(0),
           initPromise.objectForKeyedSubscript("then")?.isObject == true {
            _ = try resolvePromise(initPromise, in: ctx, label: "vm.a() init")
        } else {
            pumpMicrotasks(ctx, count: 3)
        }

        guard let snapFn = asyncSnapshotFn, !snapFn.isNull, !snapFn.isUndefined else {
            throw BotGuardError.jsFailed("asyncSnapshotFn not set after vm.a() — VM may have changed API")
        }

        // --- Phase 3: asyncSnapshotFn(callback, [undefined, undefined, webPoSignalOutput, undefined]) ---
        var botguardResponse: String?
        let webPoSignalOutput = ctx.evaluateScript("[]")!   // JS array, populated by VM
        ctx.setObject(webPoSignalOutput, forKeyedSubscript: "__bgSO" as NSString)

        let snapCallback: @convention(block) (JSValue) -> Void = { response in
            botguardResponse = response.isNull || response.isUndefined ? nil : response.toString()
        }
        let snapArgs = ctx.evaluateScript("[undefined, undefined, __bgSO, undefined]")!

        snapFn.call(withArguments: [
            JSValue(object: snapCallback, in: ctx)!,
            snapArgs
        ])
        if let exc = ctx.exception { throw BotGuardError.jsFailed("asyncSnapshotFn: \(exc)") }
        pumpMicrotasks(ctx, count: 5)   // flush in case callback fires asynchronously

        guard let bgResponse = botguardResponse, !bgResponse.isEmpty else {
            throw BotGuardError.jsFailed("botguard response empty after asyncSnapshotFn")
        }

        // --- Phase 4: fetch integrity token (blocking URLSession, safe on jsQueue) ---
        let integrityB64 = try fetchIntegrityTokenSync(bgResponse: bgResponse)
        bgLog.notice("[BotGuard] integrity token obtained (len=\(integrityB64.count))")

        // --- Phase 5: mint PO token ---
        return try mintSync(
            ctx: ctx,
            signalOutput: webPoSignalOutput,
            integrityB64: integrityB64,
            videoId: videoId
        )
    }

    // MARK: - Phase 4: integrity token (blocking, on jsQueue)

    private func fetchIntegrityTokenSync(bgResponse: String) throws -> String {
        let payload = [Self.requestKey, bgResponse]
        var req = URLRequest(url: Self.waaGenerateITURL, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.waaAPIKey,              forHTTPHeaderField: "x-goog-api-key")
        req.setValue("grpc-web-javascript/0.1",   forHTTPHeaderField: "x-user-agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        var result: Result<String, Error>?
        let sema = DispatchSemaphore(value: 0)

        session.dataTask(with: req) { data, response, error in
            defer { sema.signal() }
            if let error { result = .failure(error); return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let token = json.first as? String, !token.isEmpty else {
                result = .failure(BotGuardError.integrityTokenFailed(
                    "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                ))
                return
            }
            result = .success(token)
        }.resume()

        sema.wait()
        return try result!.get()
    }

    // MARK: - Phase 5: mint (JS, on jsQueue)

    private func mintSync(ctx: JSContext, signalOutput: JSValue, integrityB64: String, videoId: String) throws -> String {

        // Decode integrity token bytes
        guard let integrityData = Data(base64Encoded: integrityB64) else {
            throw BotGuardError.mintFailed("integrityToken base64 decode failed")
        }

        // Build JS Uint8Array for integrity token bytes
        let integrityU8 = try buildUint8Array(from: integrityData, in: ctx, label: "integrityToken")

        // getMinter = webPoSignalOutput[0]  (a function set by the VM during asyncSnapshotFn)
        guard let getMinterFn = signalOutput.objectAtIndexedSubscript(0),
              !getMinterFn.isNull, !getMinterFn.isUndefined else {
            throw BotGuardError.mintFailed("webPoSignalOutput[0] (getMinter) not set")
        }

        // mintCallback = await getMinter(integrityTokenBytes)  – may return Promise or function directly
        let getMinterResult = getMinterFn.call(withArguments: [integrityU8])
        if let exc = ctx.exception { throw BotGuardError.mintFailed("getMinter(): \(exc)") }
        let mintCallbackFn = try resolvePromise(getMinterResult ?? JSValue(undefinedIn: ctx)!, in: ctx, label: "getMinter")

        guard !mintCallbackFn.isNull, !mintCallbackFn.isUndefined else {
            throw BotGuardError.mintFailed("mintCallback is null after getMinter")
        }

        // tokenBytes = await mintCallback(TextEncoder().encode(videoId))
        guard let videoIdData = videoId.data(using: .utf8) else {
            throw BotGuardError.mintFailed("videoId UTF-8 encoding failed")
        }
        let videoIdU8 = try buildUint8Array(from: videoIdData, in: ctx, label: "videoId")

        let mintResult = mintCallbackFn.call(withArguments: [videoIdU8])
        if let exc = ctx.exception { throw BotGuardError.mintFailed("mintCallback(): \(exc)") }
        let tokenValue = try resolvePromise(mintResult ?? JSValue(undefinedIn: ctx)!, in: ctx, label: "mintCallback")

        // Extract bytes from the result (Uint8Array or plain Array)
        var tokenBytes = Data()
        if let lengthVal = tokenValue.objectForKeyedSubscript("length"), lengthVal.isNumber {
            let length = Int(lengthVal.toInt32())
            for i in 0..<length {
                let byte = tokenValue.objectAtIndexedSubscript(i).toUInt32()
                tokenBytes.append(UInt8(byte & 0xFF))
            }
        }

        guard !tokenBytes.isEmpty else {
            throw BotGuardError.mintFailed("mint result was empty")
        }

        return tokenBytes.base64EncodedString()
    }

    // MARK: - JSContext helpers

    /// Installs minimal polyfills for APIs the BotGuard interpreter JS may reference.
    private func installPolyfills(_ ctx: JSContext) {
        // window / globalThis aliasing (BotGuard may write to window.X)
        ctx.evaluateScript("""
        if (typeof window === 'undefined') { var window = this; }
        if (typeof globalThis === 'undefined') { var globalThis = window; }
        if (typeof self === 'undefined') { var self = window; }
        """)

        // Minimal document stub (prevents crashes on e.g. document.createElement)
        ctx.evaluateScript("""
        if (typeof document === 'undefined') {
            var document = {
                createElement: function(tag) { return { tagName: tag, style: {}, setAttribute: function(){}, appendChild: function(){} }; },
                createTextNode: function(t) { return { textContent: t }; },
                getElementsByTagName: function() { return []; },
                querySelector: function() { return null; },
                querySelectorAll: function() { return []; },
                head: { appendChild: function(s){ if(s && s.src){ } } },
                body: { appendChild: function(){} },
                cookie: ''
            };
        }
        """)

        // navigator stub
        ctx.evaluateScript("""
        if (typeof navigator === 'undefined') {
            var navigator = { userAgent: 'Mozilla/5.0', language: 'en-US', languages: ['en-US'], cookieEnabled: true };
        }
        """)

        // setTimeout / setInterval stubs (synchronous — fires callback immediately for best-effort compat)
        // BotGuard typically does not rely on real timer semantics in its VM.
        let setTimeoutFn: @convention(block) (JSValue, JSValue) -> NSNumber = { cb, _ in
            if cb.isObject { cb.call(withArguments: []) }
            return 0
        }
        ctx.setObject(setTimeoutFn, forKeyedSubscript: "setTimeout" as NSString)
        ctx.setObject({ (_: JSValue, _: JSValue) -> NSNumber in 0 } as @convention(block) (JSValue, JSValue) -> NSNumber,
                      forKeyedSubscript: "setInterval" as NSString)
        ctx.setObject({ (_: NSNumber) in } as @convention(block) (NSNumber) -> Void,
                      forKeyedSubscript: "clearTimeout" as NSString)
        ctx.setObject({ (_: NSNumber) in } as @convention(block) (NSNumber) -> Void,
                      forKeyedSubscript: "clearInterval" as NSString)
    }

    /// Builds a JS `Uint8Array` from `Data`. Used for passing byte arrays across the Swift/JS bridge.
    private func buildUint8Array(from data: Data, in ctx: JSContext, label: String) throws -> JSValue {
        guard let arr = ctx.evaluateScript("new Uint8Array(\(data.count))"),
              !arr.isNull, !arr.isUndefined else {
            throw BotGuardError.mintFailed("Uint8Array(\(label)) creation failed")
        }
        for (i, byte) in data.enumerated() {
            arr.setObject(NSNumber(value: byte), atIndexedSubscript: i)
        }
        return arr
    }

    /// Pumps pending JSC microtasks by re-entering the JS engine.
    /// Each call to `evaluateScript` creates a drain-point where JSC flushes its microtask queue.
    private func pumpMicrotasks(_ ctx: JSContext, count: Int) {
        for _ in 0..<count { ctx.evaluateScript("undefined") }
    }

    /// Resolves a JS Promise synchronously by installing `then`/`catch` callbacks and
    /// pumping the JSC microtask queue. Returns `promise` directly if it is not thenable.
    ///
    /// Safe to call on `jsQueue` (real OS thread). The microtask pump is `evaluateScript`
    /// which lets JSC drain its queue each time we re-enter the JS engine.
    private func resolvePromise(_ promise: JSValue, in ctx: JSContext, label: String, maxPumps: Int = 50) throws -> JSValue {
        guard let thenFn = promise.objectForKeyedSubscript("then"), thenFn.isObject else {
            return promise   // Not a thenable — mirrors JS `await nonPromise` behaviour
        }

        var resolved: JSValue?
        var rejection: String?
        let sema = DispatchSemaphore(value: 0)

        let onFulfilled: @convention(block) (JSValue) -> Void = { val in
            resolved = val; sema.signal()
        }
        let onRejected: @convention(block) (JSValue) -> Void = { err in
            rejection = err.toString(); sema.signal()
        }

        thenFn.call(withArguments: [
            JSValue(object: onFulfilled, in: ctx)!,
            JSValue(object: onRejected, in: ctx)!
        ])

        // Pump microtasks until the Promise settles (or we time out).
        for _ in 0..<maxPumps {
            ctx.evaluateScript("undefined")         // drain microtask queue
            if sema.wait(timeout: .now()) == .success { break }
        }

        guard sema.wait(timeout: .now() + .milliseconds(200)) == .success else {
            throw BotGuardError.jsFailed("Promise '\(label)' did not settle after \(maxPumps) microtask pumps")
        }

        if let reason = rejection { throw BotGuardError.jsFailed("Promise '\(label)' rejected: \(reason)") }
        return resolved ?? JSValue(undefinedIn: ctx)!
    }
}
