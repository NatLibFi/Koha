describe("circ/view_holdsqueue/holdst", () => {
    const fixtureId = Date.now().toString();
    const fixtureTitle = `KOHA-765 ${fixtureId}`;
    const tableStateKey = "DataTables_circ_view_holdsqueue_holds-table";
    const records = [
        {
            callNumber: "331",
            sortKey: "331",
        },
        {
            callNumber: "51",
            sortKey: "51",
        },
        {
            callNumber: "658",
            sortKey: "658",
        },
        {
            callNumber: "658.3",
            sortKey: "6583",
        },
    ];
    let biblioId;
    let libraryId;
    let itemTypeId;

    before(() => {
        cy.task("query", {
            sql: "SELECT s.cn_source FROM class_sources s JOIN class_sort_rules r USING (class_sort_rule) WHERE s.cn_source = 'udc' AND r.sort_routine = 'Generic'",
        }).then(sources => {
            expect(sources).to.have.length(1);
        });

        cy.task("query", {
            sql: "SELECT (SELECT branchcode FROM branches ORDER BY branchcode LIMIT 1) AS library_id, (SELECT itemtype FROM itemtypes ORDER BY itemtype LIMIT 1) AS item_type_id",
        }).then(rows => {
            expect(rows).to.have.length(1);
            libraryId = rows[0].library_id;
            itemTypeId = rows[0].item_type_id;
            expect(libraryId).to.be.a("string").and.not.be.empty;
            expect(itemTypeId).to.be.a("string").and.not.be.empty;
        });

        cy.task("getBasicAuthHeader").then(authHeader => {
            cy.request({
                method: "POST",
                url: "/api/v1/biblios",
                headers: {
                    Authorization: authHeader,
                    "Content-Type": "application/marc-in-json",
                    "x-confirm-not-duplicate": "1",
                },
                body: {
                    leader: "     nam a22     7a 4500",
                    fields: [
                        { "005": "20250120101920.0" },
                        {
                            "245": {
                                ind1: "",
                                ind2: "",
                                subfields: [{ a: fixtureTitle }],
                            },
                        },
                        {
                            "942": {
                                ind1: "",
                                ind2: "",
                                subfields: [{ c: itemTypeId }],
                            },
                        },
                    ],
                },
                followRedirect: false,
                failOnStatusCode: false,
            }).then(response => {
                expect([200, 302]).to.include(response.status);
                const location = response.headers.location;
                const locationId =
                    typeof location === "string"
                        ? location.match(/\/biblios\/(\d+)$/)?.[1]
                        : undefined;
                biblioId = Number(response.body?.id ?? locationId);
                expect(biblioId).to.be.a("number").and.greaterThan(0);

                cy.env(["kohaUsername"]).then(({ kohaUsername }) => {
                    cy.task("query", {
                        sql: "SELECT borrowernumber, surname, firstname, phone, cardnumber FROM borrowers WHERE userid = ? LIMIT 1",
                        values: [kohaUsername],
                    }).then(patrons => {
                        expect(patrons).to.have.length(1);
                        const patron = patrons[0];

                        cy.wrap(records).each((record, index) => {
                            cy.task("apiPost", {
                                endpoint: `/api/v1/biblios/${biblioId}/items`,
                                body: {
                                    external_id:
                                        `K765${fixtureId}${index}`.slice(0, 20),
                                    home_library_id: libraryId,
                                    holding_library_id: libraryId,
                                    item_type_id: itemTypeId,
                                    not_for_loan_status: 0,
                                    lost_status: 0,
                                    withdrawn: 0,
                                    damaged_status: 0,
                                    restricted_status: 0,
                                    callnumber: record.callNumber,
                                    call_number_source: "udc",
                                },
                            }).then(item => {
                                expect(item.call_number_sort).to.equal(
                                    record.sortKey
                                );
                                cy.task("query", {
                                    sql: "INSERT INTO tmp_holdsqueue (itemnumber, biblionumber, surname, firstname, phone, borrowernumber, cardnumber, reservedate, title, itemcallnumber, holdingbranch, pickbranch, notes, item_level_request) VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_DATE(), ?, ?, ?, ?, '', 1)",
                                    values: [
                                        item.item_id,
                                        biblioId,
                                        patron.surname,
                                        patron.firstname,
                                        patron.phone,
                                        patron.borrowernumber,
                                        patron.cardnumber,
                                        fixtureTitle,
                                        record.callNumber,
                                        libraryId,
                                        libraryId,
                                    ],
                                });
                            });
                        });
                    });
                });
            });
        });
    });

    after(() => {
        cy.task("query", {
            sql: "DELETE FROM biblio WHERE title = ?",
            values: [fixtureTitle],
        });
    });

    it("sorts call numbers by their classification sort keys", () => {
        const getFixtureRows = rows =>
            [...rows].filter(row =>
                row
                    .querySelector("td.hq-title")
                    .textContent.includes(fixtureTitle)
            );
        const assertFixtureRowsPresent = () =>
            cy.get("#holdst tbody tr").then(rows => {
                expect(getFixtureRows(rows)).to.have.length(records.length);
            });
        const assertFixtureOrder = () =>
            cy.get("#holdst tbody tr").then(rows => {
                const fixtureRows = getFixtureRows(rows);
                expect(fixtureRows).to.have.length(records.length);
                const callNumbers = fixtureRows.map(row =>
                    row.querySelector("td.hq-callnumber").textContent.trim()
                );
                expect(callNumbers).to.deep.equal(
                    records.map(record => record.callNumber)
                );
            });

        cy.login();
        cy.clearLocalStorage(tableStateKey);
        cy.visit(
            "/cgi-bin/koha/circ/view_holdsqueue.pl?branchlimit=&itemtypeslimit=&run_report=1"
        );

        assertFixtureRowsPresent();

        cy.get("#holdst thead th.hq-callnumber").click();
        cy.get("#holdst thead th.hq-callnumber").should(
            "have.attr",
            "aria-sort",
            "ascending"
        );

        assertFixtureOrder();

        cy.get("#holdst tbody tr").then(rows => {
            const sortKeys = getFixtureRows(rows).map(row =>
                row.querySelector("td.hq-callnumber").getAttribute("data-order")
            );
            expect(sortKeys).to.deep.equal(
                records.map(record => record.sortKey)
            );
        });

        cy.clearLocalStorage(tableStateKey);
        cy.visit(
            `/cgi-bin/koha/circ/view_holdsqueue.pl?branchlimit=${encodeURIComponent(libraryId)}&itemtypeslimit=&run_report=1`
        );
        cy.get("#holdst thead th.hq-callnumber").should(
            "not.have.attr",
            "aria-sort"
        );
        assertFixtureRowsPresent();
    });
});
