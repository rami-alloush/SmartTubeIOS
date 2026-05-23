import Foundation

extension AuthService {

    // MARK: - Persistence (delegates to TokenManager)

    func saveToKeychain() {
        let access = accessToken
        let refresh = refreshToken
        let expiry = tokenExpiry
        let name = accountName
        let avatar = accountAvatarURL
        Task {
            await tokenManager.setToken(
                access: access,
                refresh: refresh,
                expiry: expiry,
                accountName: name,
                avatarURL: avatar
            )
        }
    }

    func loadFromKeychain() {
        let snap = tokenManager.initialSnapshot
        accessToken      = snap.accessToken
        refreshToken     = snap.refreshToken
        tokenExpiry      = snap.tokenExpiry
        accountName      = snap.accountName
        accountAvatarURL = snap.accountAvatarURL
        sapisid          = snap.sapisid
        // If the stored access token has already expired, clear it so that
        // view observers (e.g. HomeView.task(id: auth.accessToken)) don't fire
        // API requests with a stale token. scheduleProactiveRefresh() will
        // obtain a fresh token and set accessToken once it succeeds.
        if let expiry = tokenExpiry, expiry <= Date() {
            accessToken = nil
        }
        isSignedIn = accessToken != nil || refreshToken != nil
        if isSignedIn { scheduleProactiveRefresh() }
        // If signed in but no SAPISID, attempt to obtain it in the background.
        // OAuthLogin may 403; falls back to Google Multilogin.
        if isSignedIn && sapisid == nil && accessToken != nil {
            Task { await self.fetchYouTubeWebCookies() }
        }
    }

    func clearKeychain() {
        Task { await tokenManager.clearToken() }
    }
}

