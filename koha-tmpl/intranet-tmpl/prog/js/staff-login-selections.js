$(function () {
    const fields = $("#loginform [data-remember-select]")
        .toArray()
        .map(checkbox => ({
            checkbox,
            select: document.getElementById(checkbox.dataset.rememberSelect),
            key: `koha.staffLogin.${checkbox.dataset.rememberKey}`,
        }));
    if (!fields.length) return;

    const [library, ...dependentFields] = fields;

    function restoreSelection(field) {
        const { checkbox, select, key } = field;
        let saved;
        try {
            saved = localStorage.getItem(key);
        } catch {
            checkbox.closest("p").hidden = true;
            return;
        }

        const available =
            saved &&
            (field === library || library.select.value) &&
            $(select)
                .find("option:enabled")
                .toArray()
                .some(option => option.value === saved);
        checkbox.checked = Boolean(available);
        checkbox.closest("p").hidden = false;
        if (available && (field !== library || !select.value)) {
            select.value = saved;
        }
    }

    function saveSelection({ checkbox, select, key }) {
        try {
            if (checkbox.checked && select.value) {
                localStorage.setItem(key, select.value);
            } else {
                localStorage.removeItem(key);
            }
        } catch {
            checkbox.closest("p").hidden = true;
        }
    }

    restoreSelection(library);
    if (library.select.value) {
        $(library.select).trigger("change");
    }
    dependentFields.forEach(restoreSelection);

    // The staff-global handler enables the selected library's desks and registers first.
    $("body").on("change", "#loginform #set-library-branch", function () {
        dependentFields.forEach(restoreSelection);
    });

    fields.forEach(field => {
        $(field.checkbox).on("change", () => saveSelection(field));
        $(field.select).on("change", function () {
            if (field.checkbox.checked) saveSelection(field);
        });
    });
});
