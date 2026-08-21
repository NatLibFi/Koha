describe("circ/pendingreserves call number sorting", () => {
    const fixtureId = Date.now().toString();
    const records = [
        {
            title: `Bug 26867 ${fixtureId} JC43`,
            items: [
                {
                    callNumber: "JC43 .G6 1890",
                    sortKey: "JC0043 G6  01890",
                },
            ],
        },
        {
            title: `Bug 26867 ${fixtureId} JC330`,
            items: [
                {
                    callNumber: "JC330 .F74 2000",
                    sortKey: "JC0330 F74  02000",
                },
            ],
        },
        {
            title: `Bug 26867 ${fixtureId} JC480`,
            items: [
                {
                    callNumber: "JC480 .R63 2006",
                    sortKey: "JC0480 R63  02006",
                },
            ],
        },
        {
            title: `Bug 26867 ${fixtureId} multiple call numbers`,
            items: [
                {
                    callNumber: "JC480 .R63 2006",
                    sortKey: "JC0480 R63  02006",
                },
                {
                    callNumber: "JC43 .G6 1890",
                    sortKey: "JC0043 G6  01890",
                },
            ],
        },
        {
            title: `Bug 26867 ${fixtureId} missing sort key`,
            items: [
                {
                    callNumber: "ZZ999 .X1",
                    sortKey: null,
                },
            ],
        },
    ];
    const biblioIds = [];
    let libraryId;
    let itemType;

    before(() => {
        cy.task("query", {
            sql: "SELECT branchcode FROM branches ORDER BY branchcode LIMIT 1",
        }).then(libraries => {
            libraryId = libraries[0].branchcode;

            cy.task("query", {
                sql: "SELECT itemtype FROM itemtypes ORDER BY itemtype LIMIT 1",
            }).then(itemTypes => {
                itemType = itemTypes[0].itemtype;

                cy.env(["kohaUsername"]).then(({ kohaUsername }) => {
                    cy.task("query", {
                        sql: "SELECT borrowernumber FROM borrowers WHERE userid = ? LIMIT 1",
                        values: [kohaUsername],
                    }).then(patrons => {
                        const borrowernumber = patrons[0].borrowernumber;
                        let itemIndex = 0;

                        records.forEach(record => {
                            cy.task("query", {
                                sql: "INSERT INTO biblio (title, datecreated) VALUES (?, CURRENT_DATE())",
                                values: [record.title],
                            }).then(biblioResult => {
                                const biblioId = biblioResult.insertId;
                                biblioIds.push(biblioId);

                                cy.task("query", {
                                    sql: "INSERT INTO biblioitems (biblionumber, itemtype, cn_source) VALUES (?, ?, 'lcc')",
                                    values: [biblioId, itemType],
                                }).then(biblioitemResult => {
                                    record.items.forEach(item => {
                                        itemIndex += 1;
                                        cy.task("query", {
                                            sql: "INSERT INTO items (biblionumber, biblioitemnumber, barcode, homebranch, holdingbranch, itemcallnumber, cn_source, cn_sort, itype) VALUES (?, ?, ?, ?, ?, ?, 'lcc', ?, ?)",
                                            values: [
                                                biblioId,
                                                biblioitemResult.insertId,
                                                `B26867${fixtureId}${itemIndex}`.slice(
                                                    0,
                                                    20
                                                ),
                                                libraryId,
                                                libraryId,
                                                item.callNumber,
                                                item.sortKey,
                                                itemType,
                                            ],
                                        });
                                    });

                                    cy.task("query", {
                                        sql: "INSERT INTO reserves (borrowernumber, reservedate, biblionumber, branchcode, priority, found, suspend, item_level_hold) VALUES (?, CURRENT_DATE(), ?, ?, 1, NULL, 0, 0)",
                                        values: [
                                            borrowernumber,
                                            biblioId,
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
    });

    after(() => {
        if (biblioIds.length) {
            cy.task("query", {
                sql: `DELETE FROM biblio WHERE biblionumber IN (${biblioIds.map(() => "?").join(",")})`,
                values: biblioIds,
            });
        }
    });

    it("sorts rows and aggregated values by classification sort keys", () => {
        const assertRowOrder = expectedRecords =>
            cy.get("#holdst tbody tr").then(rows => {
                const titles = [...rows].map(row =>
                    row.querySelector("td:nth-child(5)").textContent.trim()
                );
                const rowOrder = expectedRecords.map(record =>
                    titles.findIndex(title => title.includes(record.title))
                );

                rowOrder.forEach(index => expect(index).to.be.greaterThan(-1));
                expect(rowOrder).to.eql([...rowOrder].sort((a, b) => a - b));
            });

        cy.login();
        cy.visit(
            "/cgi-bin/koha/circ/pendingreserves.pl?from=2000-01-01&to=2999-12-31&run_report=Submit"
        );

        records.forEach(record => {
            const expectedSortKey = [...record.items].sort((a, b) =>
                (a.sortKey ?? a.callNumber).localeCompare(
                    b.sortKey ?? b.callNumber
                )
            )[0];
            cy.contains("#holdst tbody tr", record.title)
                .find("td")
                .eq(7)
                .should(
                    "have.attr",
                    "data-order",
                    expectedSortKey.sortKey ?? expectedSortKey.callNumber
                );
        });

        cy.contains("#holdst tbody tr", records[3].title)
            .find("td")
            .eq(7)
            .find("li")
            .then(items => {
                expect([...items].map(item => item.textContent.trim())).to.eql([
                    records[3].items[1].callNumber,
                    records[3].items[0].callNumber,
                ]);
            });

        cy.get("#holdst thead tr:eq(0) th:eq(7)").click();
        cy.get("#holdst thead tr:eq(0) th:eq(7)").should(
            "have.attr",
            "aria-sort",
            "ascending"
        );

        assertRowOrder(records.slice(0, 3));

        cy.get("#holdst thead tr:eq(0) th:eq(7)").click();
        cy.get("#holdst thead tr:eq(0) th:eq(7)").should(
            "have.attr",
            "aria-sort",
            "descending"
        );
        assertRowOrder(records.slice(0, 3).reverse());
    });
});
