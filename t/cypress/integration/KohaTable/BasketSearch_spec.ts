describe("Basket search with the production KohaTable and DataTables", () => {
    const assetPaths = [
        "koha-tmpl/intranet-tmpl/lib/jquery/jquery-3.6.0.min.js",
        "koha-tmpl/intranet-tmpl/lib/datatables/datatables.min.js",
        "koha-tmpl/intranet-tmpl/prog/js/datatables.js",
        "koha-tmpl/intranet-tmpl/prog/js/acquisitions-basket.js",
    ];
    const assets = [];
    const stateKey = "DataTables_acqui_basket_orders";
    const input = id => cy.get(`#${id}_wrapper input[type=search]`);
    const rows = (id, count, text = "") => {
        cy.get(`#${id} tbody tr`).should("have.length", count);
        if (text) cy.get(`#${id} tbody`).should("contain.text", text);
    };

    before(() => {
        assetPaths.forEach(path => {
            cy.readFile(path).then(source => assets.push(source));
        });
    });

    beforeEach(() => {
        assets.forEach((body, index) => {
            cy.intercept("GET", `/__basket-search-assets/${index}.js`, {
                headers: { "content-type": "application/javascript" },
                body,
            });
        });
    });

    function mount(restoreSearch = true, reset = true) {
        // Serve a synthetic page: no login, database fixtures or application request.
        cy.intercept("GET", "/__basket-search-test", {
            headers: { "content-type": "text/html" },
            body: `<!doctype html><html><meta charset="utf-8"><body>
                <script>
                    window.__ = window._ = text => text;
                    window.CAN_user_parameters_manage_column_config = false;
                    window.alert = message => { throw new Error(message); };
                    String.prototype.format = function (...args) {
                        let i = 0;
                        return this.replace(/%s/g, () => args[i++]);
                    };
                    ${reset ? `localStorage.removeItem("${stateKey}");` : ""}
                    window.foreignInputEvents = 0;
                </script>
                ${assets.map((_, i) => `<script src="/__basket-search-assets/${i}.js"></script>`).join("")}
                <table id="orders"><thead><tr><th>Details</th></tr></thead><tbody>
                    <tr><td>Alpha garden 978-1-234-56789-7</td></tr>
                    <tr><td>Beta garden 1-2345-6789-X</td></tr>
                    <tr><td>Gamma periodical 1234-567X</td></tr>
                    <tr><td>Literal [guide]. C++ A-B &quot;quoted&quot;</td></tr>
                </tbody></table>
                <table id="cancelledorderst"><thead><tr><th>Details</th></tr></thead><tbody>
                    <tr><td>Delta garden 978-1-234-56789-7</td></tr>
                    <tr><td>Epsilon 2049-3630</td></tr>
                </tbody></table>
                <table id="unrelated"><thead><tr><th>Other</th></tr></thead><tbody>
                    <tr><td>Unrelated one</td></tr><tr><td>Unrelated two</td></tr>
                </tbody></table>
                <script>
                    const settings = {
                        module: "acqui", page: "basket", table: "orders",
                        default_save_state: true,
                        default_save_state_search: ${restoreSearch},
                        columns: [{ columnname: "details" }],
                    };
                    $("#orders").kohaTable({
                        initComplete: function (settings) {
                            $(new DataTable.Api(settings).table().container())
                                .find("input[type=search]")
                                .on("input.fixture", () => window.foreignInputEvents++);
                            initBasketSearch(settings);
                        },
                    }, settings);
                    $("#cancelledorderst").kohaTable({ initComplete: initBasketSearch });
                    // A third table exposed the legacy global search callback's leakage.
                    $("#unrelated").kohaTable();
                </script>
                </body></html>`,
        });
        cy.visit("/__basket-search-test");
        cy.window().should(win => {
            ["orders", "cancelledorderst", "unrelated"].forEach(id => {
                expect(win.jQuery.fn.dataTable.isDataTable(`#${id}`)).to.be
                    .true;
                expect(win.jQuery(`#${id}`).DataTable().ready()).to.be.true;
            });
        });
    }

    it("matches full and partial identifiers, checksum X, and literal text", () => {
        mount();
        [
            ["9781234567897", "Alpha"],
            ["978-1-234-56789-7", "Alpha"],
            ["9781", "Alpha"],
            ["978-1", "Alpha"],
            ["9-7-8-1-2-3-4-5-6-7-8-9-7", "Alpha"],
            ["123456789x", "Beta"],
            ["1-2345-6789-X", "Beta"],
            ["1234567x", "Gamma"],
            ["1234-567X", "Gamma"],
            ["[guide].", "Literal"],
            ["C++", "Literal"],
            ["A-B", "Literal"],
            ['"quoted"', "Literal"],
        ].forEach(([term, title]) => {
            input("orders")
                .clear()
                .type(term, { parseSpecialCharSequences: false });
            input("orders").should("have.value", term).blur();
            rows("orders", 1, title);
        });
        input("orders").clear().type("6789");
        rows("orders", 2);
        input("orders").clear().type("garden Alpha");
        cy.window().should(win => {
            expect(
                win
                    .jQuery("#orders")
                    .DataTable()
                    .rows({ search: "applied" })
                    .count()
            ).to.eq(0);
            expect(win.foreignInputEvents).to.be.greaterThan(0);
        });
        rows("cancelledorderst", 2);
        rows("unrelated", 2);
    });

    it("keeps tables independent and honours shared clear and API searches", () => {
        mount();
        input("orders").type("9781");
        input("cancelledorderst").type("20493630");
        rows("orders", 1, "Alpha");
        rows("cancelledorderst", 1, "Epsilon");
        cy.get("#orders_wrapper .dt_button_clear_filter").click();
        input("orders").should("have.value", "");
        rows("orders", 4);
        rows("cancelledorderst", 1, "Epsilon");
        cy.window().then(win => {
            win.jQuery("#orders").DataTable().search("1234-567X").draw();
        });
        input("orders").should("have.value", "1234-567X");
        rows("orders", 1, "Gamma");
        // A later draw must not reinterpret the derived regex as a new raw term.
        cy.window().then(win => {
            win.jQuery("#orders").DataTable().order([0, "desc"]).draw();
            win.jQuery("#unrelated").DataTable().search("two").draw();
        });
        input("orders").should("have.value", "1234-567X");
        rows("orders", 1, "Gamma");
        rows("unrelated", 1, "Unrelated two");
        input("orders").focus();
        cy.window().then(win => {
            win.jQuery("#orders").DataTable().search("").draw("page");
        });
        input("orders").should("have.value", "");
        rows("orders", 4);
        input("cancelledorderst").clear().trigger("search");
        rows("cancelledorderst", 2);
    });

    it("restores the raw term only when native settings restore search", () => {
        mount();
        input("orders").type("978-1").blur();
        input("cancelledorderst").type("2049").blur();
        rows("cancelledorderst", 1, "Epsilon");
        cy.window().then(win => {
            win.jQuery("#orders").DataTable().state.save();
            const state = JSON.parse(win.localStorage.getItem(stateKey));
            expect(state.search.search).to.eq("978-1");
            expect(state.search.regex).to.be.false;
            expect(state.search.smart).to.be.false;
        });
        mount(true, false);
        input("orders").should("have.value", "978-1");
        rows("orders", 1, "Alpha");
        input("cancelledorderst").should("have.value", "");
        rows("cancelledorderst", 2);
        mount(false, false);
        input("orders").should("have.value", "");
        rows("orders", 4);
        cy.window().then(win => {
            win.jQuery("#orders").DataTable().state.save();
            expect(
                JSON.parse(win.localStorage.getItem(stateKey)).search.search
            ).to.eq("");
        });
    });
});
