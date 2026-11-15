actor AsyncSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func fire() { fired = true; let all = waiters; waiters = []; for waiter in all { waiter.resume() } }
    func wait() async { if !fired { await withCheckedContinuation { waiters.append($0) } } }
}
