self.onmessage = async event => {
    const match =
        /^q1\.[0-9]{8}\.[0-9]{10}\.([0-9]{2})\.([0-9a-f]{32})\.[0-9a-f]{16}\.[0-9a-f]{64}$/.exec(
            event.data.challenge
        );
    if (!match || !crypto.subtle) {
        self.postMessage({ error: true });
        return;
    }
    const difficulty = Number(match[1]);
    if (difficulty < 1 || difficulty > 24) {
        self.postMessage({ error: true });
        return;
    }
    const seed = match[2];
    const encoder = new TextEncoder();
    const deadline = performance.now() + 30000;
    const whole = Math.floor(difficulty / 8);
    const remaining = difficulty % 8;
    try {
        for (let first = 0; first <= 4294967264; first += 32) {
            if (performance.now() > deadline) break;
            const hashes = await Promise.all(
                Array.from({ length: 32 }, (_, offset) =>
                    crypto.subtle.digest(
                        "SHA-256",
                        encoder.encode(seed + ":" + (first + offset))
                    )
                )
            );
            for (let offset = 0; offset < hashes.length; offset++) {
                const bytes = new Uint8Array(hashes[offset]);
                let valid = true;
                for (let i = 0; i < whole; i++) {
                    if (bytes[i] !== 0) valid = false;
                }
                if (remaining && bytes[whole] >>> (8 - remaining) !== 0)
                    valid = false;
                if (valid) {
                    self.postMessage({ counter: first + offset });
                    return;
                }
            }
        }
    } catch (_) {
        // A failed computation must not trigger an endless retry loop.
    }
    self.postMessage({ error: true });
};
