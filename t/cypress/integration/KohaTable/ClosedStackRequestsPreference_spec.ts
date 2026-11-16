describe("EnableClosedStackRequests staff workflow", () => {
    const preference = "EnableClosedStackRequests";
    const home = "/cgi-bin/koha/circ/circulation-home.pl";
    const queue = "/cgi-bin/koha/circ/closed-stack-requests.pl";
    let originalPreference;

    before(() => {
        cy.task("query", {
            sql: "SELECT value FROM systempreferences WHERE variable = ?",
            values: [preference],
        }).then(rows => {
            expect(rows, "installed preference").to.have.length(1);
            originalPreference = rows[0].value;
        });
    });

    after(() => {
        if (originalPreference !== undefined) {
            cy.login();
            cy.set_syspref(preference, originalPreference);
        }
    });

    it("exposes the queue when enabled", () => {
        cy.login();
        cy.set_syspref(preference, "1");
        cy.visit(home);
        cy.get(`a.circ-button[href='${queue}']`).should("be.visible").click();
        cy.location("pathname").should("eq", queue);
        cy.get("h1").should("contain", "Closed stack requests");
    });

    it("hides and rejects the queue while ordinary holds reports remain available", () => {
        cy.login();
        cy.set_syspref(preference, "0");
        cy.visit(home);
        cy.get(`a[href='${queue}']`).should("not.exist");
        cy.get("a.circ-button[href*='view_holdsqueue.pl']").should(
            "be.visible"
        );
        cy.get("a.circ-button[href*='pendingreserves.pl']").should(
            "be.visible"
        );
        cy.visit(queue);
        cy.location("pathname").should("eq", home);
    });

    it("restores the queue after re-enabling", () => {
        cy.login();
        cy.set_syspref(preference, "1");
        cy.visit(home);
        cy.get(`a.circ-button[href='${queue}']`).should("be.visible");
    });
});
