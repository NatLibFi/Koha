document.addEventListener("DOMContentLoaded", () => {
    const root = "/opac-tmpl/lib/koha_fast_challenge/";
    const status = document.getElementById("challenge-status");
    const retry = document.getElementById("challenge-retry");
    const spinner = document.querySelector(".spinner");
    let worker;
    let running = false;

    async function fetchWithTimeout(url, options) {
        const timeoutMs = 10000;
        if (typeof AbortSignal.timeout === "function") {
            return fetch(url, { ...options, signal: AbortSignal.timeout(timeoutMs) });
        }

        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), timeoutMs);
        try {
            return await fetch(url, { ...options, signal: controller.signal });
        } finally {
            clearTimeout(timer);
        }
    }

    const solve = challenge =>
        new Promise((resolve, reject) => {
            worker = new Worker(root + "pow-worker.js");
            worker.onmessage = event => {
                worker.terminate();
                worker = null;
                if (event.data.error) reject(new Error("Proof of work failed"));
                else resolve(event.data.counter);
            };
            worker.onerror = () => {
                worker.terminate();
                worker = null;
                reject(new Error("Proof of work is unavailable"));
            };
            worker.postMessage({ challenge });
        });

    function stop(message) {
        status.textContent = message;
        retry.hidden = false;
        spinner.hidden = true;
        running = false;
    }

    async function run() {
        if (running) return;
        running = true;
        retry.hidden = true;
        spinner.hidden = false;
        status.textContent = "Checking your browser…";
        try {
            const issued = await fetchWithTimeout(root + "issue", {
                cache: "no-store",
                credentials: "same-origin",
            });
            const challenge = issued.headers.get("X-Koha-Challenge");
            if (issued.status !== 204 || !challenge)
                throw new Error("Challenge unavailable");
            const counter = await solve(challenge);
            const verified = await fetchWithTimeout(root + "solve", {
                method: "POST",
                cache: "no-store",
                credentials: "same-origin",
                headers: {
                    "X-Koha-Challenge": challenge,
                    "X-Koha-Proof": String(counter),
                },
            });
            if (verified.status !== 204) throw new Error("Verification failed");

            // Reload only when the server saw the cookie come back; a browser
            // that refuses it would otherwise solve and reload forever.
            const checked = await fetchWithTimeout(root + "check", {
                cache: "no-store",
                credentials: "same-origin",
            });
            if (checked.status !== 204) throw new Error("Check unavailable");
            if (checked.headers.get("X-Koha-Clearance") !== "ok") {
                stop(
                    "We could not confirm your verification cookie. Please allow cookies for this site and try again."
                );
                return;
            }
            location.reload();
        } catch (_) {
            stop("Browser verification could not finish. Please try again.");
        }
    }

    retry.addEventListener("click", run);
    window.addEventListener("pagehide", () => {
        if (worker) worker.terminate();
    });
    run();
});
