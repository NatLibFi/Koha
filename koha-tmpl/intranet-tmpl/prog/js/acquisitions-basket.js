/* global DataTable */

function initBasketSearch(settings) {
    const api = new DataTable.Api(settings);
    const table = $(api.table().node());
    const input = $(api.table().container()).find(
        `input[aria-controls="${api.table().node().id}"][type="search"]`
    );
    let raw = api.search();
    let searchSource = raw;
    let applying = false;

    function apply(value, draw) {
        raw = value;
        const identifier = value.trim();
        // Keep partial identifiers useful while typing, including checksum X.
        const source = /^\d[\d-]*x?$/i.test(identifier)
            ? identifier.replace(/-/g, "").split("").join("-*")
            : DataTable.util.escapeRegex(value);
        searchSource = source;
        applying = true;
        api.search(source, {
            regex: true,
            smart: false,
            caseInsensitive: true,
        });
        applying = false;
        input.val(raw);
        if (draw) api.draw();
    }

    // Retain native form/Enter protection and any non-DataTables handlers.
    input
        .off("keyup.DT search.DT input.DT paste.DT cut.DT mouseup.DT")
        .on(
            "input.basketSearch search.basketSearch keyup.basketSearch",
            function () {
                if (this.value !== raw) apply(this.value, true);
            }
        );

    table
        .on("search.dt.basketSearch", function (event, settings) {
            if (settings.nTable !== table[0] || applying) return;
            // Honour external string searches, including the shared clear button.
            const value = api.search();
            if (value === searchSource) {
                input.val(raw);
            } else if (typeof value === "string") {
                apply(value, false);
            }
        })
        .on(
            "stateSaveParams.dt.basketSearch",
            function (event, settings, data) {
                if (settings.nTable !== table[0]) return;
                // Save the user's term, not the derived regex. Native restore remains
                // responsible for deciding whether search state may be restored.
                data.search.search = raw;
                data.search.regex = false;
                data.search.smart = false;
            }
        )
        .on("destroy.dt.basketSearch", function () {
            input.off(".basketSearch");
            table.off(".basketSearch");
        });

    if (raw) apply(raw, true);
}
