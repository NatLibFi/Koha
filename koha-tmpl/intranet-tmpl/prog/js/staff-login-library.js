$(function () {
    const checkbox = $("#remember-library-checkbox");
    if (!checkbox.length) return;

    const library = $("#set-library-branch");
    const storageKey = "koha.staffLogin.library";

    let rememberedLibrary;
    try {
        rememberedLibrary = localStorage.getItem(storageKey);
    } catch {
        return;
    }

    if (
        rememberedLibrary &&
        library
            .find("option:enabled")
            .toArray()
            .some(option => option.value === rememberedLibrary)
    ) {
        checkbox.prop("checked", true);
        if (!library.val()) {
            library.val(rememberedLibrary).trigger("change");
        }
    }

    $("#remember-library").prop("hidden", false);
    checkbox.add(library).on("change", function () {
        const selectedLibrary = library.val();
        try {
            if (checkbox.prop("checked") && selectedLibrary) {
                localStorage.setItem(storageKey, selectedLibrary);
            } else {
                localStorage.removeItem(storageKey);
            }
        } catch {
            $("#remember-library").prop("hidden", true);
        }
    });
});
