copyValueToClipboard = async (target, value) => {
    if (!value) {
        return;
    }

    try {
        await navigator.clipboard.writeText(value);
    } catch (err) {
        return;
    }

    const saved_title = target.title;
    target.title = __("Copied to clipboard");
    const tooltip = bootstrap.Tooltip.getOrCreateInstance(target);
    tooltip.show();
    setTimeout(() => {
        const t = bootstrap.Tooltip.getInstance(target);
        if (t) {
            t.dispose();
            target.title = saved_title;
        }
    }, 3000);
};

(() => {
    const copyToClipboardButtons = document.querySelectorAll(
        "[data-copy-to-clipboard]"
    );

    if (copyToClipboardButtons.length) {
        async function copyToClipboard(e) {
            const target = this;
            if (!(target instanceof HTMLButtonElement)) {
                return;
            }
            const { value } = target.dataset;
            await copyValueToClipboard(target, value);
        }

        copyToClipboardButtons.forEach(copyToClipboardButton => {
            copyToClipboardButton.addEventListener("click", copyToClipboard);
        });
    }
})();
