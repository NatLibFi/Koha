document.addEventListener("DOMContentLoaded", () => {
    const root = "/opac-tmpl/lib/koha_fast_challenge/";
    const status = document.getElementById("challenge-status");
    const retry = document.getElementById("challenge-retry");
    const spinner = document.querySelector(".spinner");
    let worker;
    let running = false;

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

    async function run() {
        if (running) return;
        running = true;
        retry.hidden = true;
        spinner.hidden = false;
        status.textContent = "Checking your browser…";
        try {
            const issued = await fetch(root + "issue", {
                cache: "no-store",
                credentials: "same-origin",
                signal: AbortSignal.timeout(10000),
            });
            const challenge = issued.headers.get("X-Koha-Challenge");
            if (issued.status !== 204 || !challenge)
                throw new Error("Challenge unavailable");
            const counter = await solve(challenge);
            const verified = await fetch(root + "solve", {
                method: "POST",
                cache: "no-store",
                credentials: "same-origin",
                headers: {
                    "X-Koha-Challenge": challenge,
                    "X-Koha-Proof": String(counter),
                },
                signal: AbortSignal.timeout(10000),
            });
            if (verified.status !== 204) throw new Error("Verification failed");
            location.reload();
        } catch (_) {
            status.textContent =
                "Browser verification could not finish. Please try again.";
            retry.hidden = false;
            spinner.hidden = true;
            running = false;
        }
    }

    retry.addEventListener("click", run);
    window.addEventListener("pagehide", () => {
        if (worker) worker.terminate();
    });
    run();
});
