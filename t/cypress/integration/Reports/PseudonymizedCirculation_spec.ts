describe("Circulation statistics: optional retained history", () => {
    const page = "/cgi-bin/koha/reports/issues_stats.pl";
    let marker;

    function requestParams() {
        const params = new URLSearchParams({
            data_source: "pseudonymized",
            Line: "borrowers.sort2",
            Column: "datetime",
            Cellvalue: "3",
            PeriodTypeSel: "issue",
            sep: ",",
        });
        const filters = [
            "2011-01-02",
            "2011-01-03",
            "",
            "",
            "",
            "",
            "",
            marker,
            `${marker}z`,
            "",
            "",
            "",
            "",
            "",
        ];
        filters.forEach(value => params.append("Filter", value));
        return params;
    }

    beforeEach(() => {
        marker = `cy771${Date.now()}`;
        cy.login();
        // Synthetic retained rows only: no worker, preference or live history
        // mutation. There are deliberately no corresponding statistics rows.
        cy.task(
            "query",
            `INSERT INTO pseudonymized_transactions
            (hashed_borrowernumber, branchcode, categorycode, datetime,
             transaction_type, itemnumber, itemcallnumber, sort2)
            VALUES
            ('cy771-private-hash', '', '', '2011-01-02 00:00:00', 'issue', 771, '${marker}', 'csv "quote", value'),
            ('cy771-private-hash', '', '', '2011-01-03 23:59:59', 'issue', 771, '${marker}', 'csv "quote", value')`
        );
    });

    afterEach(() => {
        cy.task(
            "query",
            `DELETE FROM pseudonymized_transactions WHERE itemcallnumber = '${marker}'`
        );
    });

    it("keeps statistics as default and changes available controls with the source", () => {
        cy.visit(page);
        cy.get("#data_source").should("have.value", "statistics");
        cy.get("#cellvalue5").check();
        cy.get("#data_source").select("pseudonymized");
        cy.get("#cellvalue5").should("be.disabled").and("not.be.checked");
        cy.get("#cellvalue1").should("be.checked");
        cy.get("#PeriodTypeSel option[value='localuse']").should("be.disabled");
        cy.get(".pseudonymized-source-help").should("be.visible");
        cy.get("#data_source").select("statistics");
        cy.get("#cellvalue5").should("be.enabled");
        cy.get("input[name='Filter'], select[name='Filter']").should(
            "have.length",
            14
        );
    });

    it("reports without raw history and uses the same source and distinct total in CSV", () => {
        cy.visit(page);
        cy.get("#data_source").select("pseudonymized");
        cy.get("input[name='Line'][value='borrowers.sort2']").check();
        cy.get("input[name='Column'][value='datetime']").check();
        cy.get("#cellvalue3").check();
        cy.get("#branch").select("");
        cy.get("#from").then(input =>
            input[0]._flatpickr.setDate("2011-01-02", true, "Y-m-d")
        );
        cy.get("#from").should("have.value", "2011-01-02");
        cy.get("#to").then(input =>
            input[0]._flatpickr.setDate("2011-01-03", true, "Y-m-d")
        );
        cy.get("#to").should("have.value", "2011-01-03");
        cy.get("input[name='Filter'], select[name='Filter']")
            .eq(7)
            .type(marker);
        cy.get("input[name='Filter'], select[name='Filter']")
            .eq(8)
            .type(`${marker}z`);
        cy.get("input[name='do_it']").closest("form").submit();
        cy.get("#circulation-statistics-results tr")
            .eq(1)
            .find("td")
            .then(cells => {
                expect(
                    [...cells].map(cell => cell.textContent.trim())
                ).to.deep.eq(['csv "quote", value', "1", "1", "1"]);
            });
        const params = requestParams();
        params.set("do_it", "1");
        params.set("output", "file");
        cy.request(`${page}?${params}`).then(response => {
            expect(response.headers["content-type"]).to.include("text/csv");
            expect(response.body).to.include(
                "Retained pseudonymized transactions"
            );
            expect(response.body).to.include('"csv ""quote"", value",1,1,1');
            expect(response.body).not.to.include("cy771-private-hash");
        });
    });

    it("rejects unsupported pseudo measures on the server", () => {
        const params = requestParams();
        params.set("do_it", "1");
        params.set("Cellvalue", "5");
        cy.visit(`${page}?${params}`);
        cy.get("#report-error").should("be.visible");
        cy.get("#circulation-statistics-results").should("not.exist");
    });
});
