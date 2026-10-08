import Foundation

@MainActor
extension AuthState {
    // MARK: - Subscription

    var canUseCloudASR: Bool {
        !isLoadingSubscription
            && subscriptionError == nil
            && subscription.cloudASRAllowed
    }

    func refreshSubscriptionIfNeeded() {
        guard isLoggedIn || accessToken != nil else { return }
        Task { await refreshSubscription() }
    }

    @discardableResult
    func refreshSubscription() async -> BillingSubscriptionSnapshot? {
        guard let token = accessToken else {
            subscription = .none
            return nil
        }
        guard !isLoadingSubscription else { return subscription }

        isLoadingSubscription = true
        defer { isLoadingSubscription = false }

        do {
            let snapshot = try await fetchSubscription(token)
            applySubscriptionSnapshot(snapshot)
            return snapshot
        } catch let error as AuthError {
            subscriptionError = error.localizedDescription
            return nil
        } catch {
            subscriptionError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func syncSubscription() async throws -> BillingSubscriptionSnapshot {
        guard let token = accessToken else {
            throw AuthError.unauthorized
        }
        guard !isSyncingSubscription else { return subscription }

        isSyncingSubscription = true
        defer { isSyncingSubscription = false }

        let snapshot = try await syncBillingSubscription(token)
        applySubscriptionSnapshot(snapshot)
        return snapshot
    }

    @discardableResult
    func refreshUsage() async -> CloudUsageStats? {
        guard let token = accessToken else {
            usageStats = .empty
            usageCredits = nil
            return nil
        }
        guard !isLoadingUsage else { return usageStats }

        isLoadingUsage = true
        defer { isLoadingUsage = false }

        do {
            let snapshot = try await fetchCurrentPeriodUsageStats(token)
            usageStats = snapshot.stats
            usageCredits = snapshot.credits
            usagePeriodStart = snapshot.periodStart
            usagePeriodEnd = snapshot.periodEnd
            usageError = nil
            return snapshot.stats
        } catch let error as AuthError {
            if error.authErrorCode == "USAGE_PERIOD_UNAVAILABLE" {
                usageStats = .empty
                usageCredits = nil
                usagePeriodStart = nil
                usagePeriodEnd = nil
                usageError = nil
            } else {
                usageError = error.localizedDescription
            }
            return nil
        } catch {
            usageError = error.localizedDescription
            return nil
        }
    }

    /// Refreshes the subscription and the period's usage unless they were
    /// fetched within `maxAge` (the account card asks on every hover).
    func refreshAccountSummary(maxAge: TimeInterval = 60, now: Date = Date()) async {
        guard isLoggedIn else { return }
        if let last = lastAccountSummaryRefresh, now.timeIntervalSince(last) < maxAge { return }
        lastAccountSummaryRefresh = now
        await refreshTokenIfNeeded()
        await refreshSubscription()
        await refreshUsage()
    }

    /// Makes the next `refreshAccountSummary` fetch, e.g. after opening billing.
    func invalidateAccountSummary() {
        lastAccountSummaryRefresh = nil
    }

    /// Loads the per-day / per-feature credit breakdown. Failures (including a
    /// server that predates the endpoint) clear it so the charts hide quietly.
    @discardableResult
    func refreshUsageBreakdown(timeZone: TimeZone = .current) async -> CloudUsageBreakdown? {
        guard let token = accessToken else {
            usageBreakdown = nil
            return nil
        }
        guard !isLoadingUsageBreakdown else { return usageBreakdown }

        isLoadingUsageBreakdown = true
        defer { isLoadingUsageBreakdown = false }

        do {
            let breakdown = try await fetchCurrentPeriodUsageBreakdown(token, timeZone)
            usageBreakdown = breakdown
            return breakdown
        } catch is CancellationError {
            return usageBreakdown
        } catch {
            logger.info("Usage breakdown unavailable: \(error.localizedDescription, privacy: .public)")
            usageBreakdown = nil
            return nil
        }
    }

    func startCheckout(planCode: String = BillingPlan.defaultPlanCode) async throws -> URL {
        guard let token = accessToken else {
            throw AuthError.unauthorized
        }
        let session = try await createCheckoutSession(token, planCode)
        if !subscription.hasPaidSubscription {
            pendingCheckoutSubscriptionEntitlement = true
        }
        startCheckoutPolling()
        return session.url
    }

    func createBillingPortalSession() async throws -> URL {
        guard let token = accessToken else {
            throw AuthError.unauthorized
        }
        let session = try await createPortalSession(token)
        return session.url
    }

    func requestBillingPageToken() async throws -> URL {
        guard let token = accessToken else {
            throw AuthError.unauthorized
        }
        let response = try await issueBillingPageToken(token)
        return response.plansURL
    }

    /// The billing page opened on `tab`, e.g. `BillingPlansLink.creditsTab`.
    func requestBillingPageToken(tab: String?) async throws -> URL {
        try await BillingPlansLink.url(requestBillingPageToken(), tab: tab)
    }

    private func startCheckoutPolling() {
        checkoutPollingTask?.cancel()
        checkoutPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0 ..< Self.checkoutPollingAttempts {
                if attempt > 0 {
                    try? await Task.sleep(for: Self.checkoutPollingInterval)
                }
                guard !Task.isCancelled else { return }
                _ = await refreshSubscription()
                if subscription.hasPaidSubscription {
                    return
                }
            }
            pendingCheckoutSubscriptionEntitlement = false
        }
    }

    private func applySubscriptionSnapshot(_ snapshot: BillingSubscriptionSnapshot) {
        let wasEntitled = subscription.entitled
        let hadPaidSubscription = subscription.hasPaidSubscription
        let subscriptionChanged = subscription != snapshot
        subscription = snapshot
        subscriptionError = nil
        if subscriptionChanged {
            NotificationCenter.default.post(name: .authSubscriptionDidChange, object: self)
        }
        let becameEntitled = !wasEntitled && snapshot.entitled
        let becamePaid = !hadPaidSubscription && snapshot.hasPaidSubscription
        if pendingCheckoutSubscriptionEntitlement, becameEntitled || becamePaid {
            pendingCheckoutSubscriptionEntitlement = false
            NotificationCenter.default.post(name: .authCheckoutSubscriptionDidBecomeEntitled, object: self)
        }
    }
}
