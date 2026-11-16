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
                    callNumber: "JC330 .F74 2000",
                    sortKey: "JC0330 F74  02000",
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
    let originalPreference;
    const preference = "HoldsCallnumberSortToPull";

    before(() => {
        cy.task("query", {
            sql: "SELECT value FROM systempreferences WHERE variable = ?",
            values: [preference],
        }).then(rows => {
            expect(
                rows,
                "installed HoldsCallnumberSortToPull preference"
            ).to.have.length(1);
            originalPreference = rows[0].value;
        });
        cy.task("query", {
            sql: "SELECT branchcode FROM branches ORDER BY branchcode LIMIT 1",
        }).then(libraries => {
            libraryId = libraries[0].branchcode;

            cy.task("query", {
                sql: "SELECT itemtype FROM itemtypes ORDER BY itemtype LIMIT 1",
            }).then(itemTypes => {
                itemType = itemTypes[0].itemtype;

                cy.wrap(Cypress.env("apiUsername")).then(kohaUsername => {
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
        if (originalPreference !== undefined) {
            cy.set_syspref(preference, originalPreference);
        }
        if (biblioIds.length) {
            cy.task("query", {
                sql: `DELETE FROM biblio WHERE biblionumber IN (${biblioIds.map(() => "?").join(",")})`,
                values: biblioIds,
            });
        }
    });

    const reportUrl =
        "/cgi-bin/koha/circ/pendingreserves.pl?from=2000-01-01&to=2999-12-31&run_report=Submit";
    const stateKey = "DataTables_circ_holds_holds-to-pull";

    const getTable = () =>
        cy
            .window()
            .should(win => {
                expect(win.jQuery?.fn.dataTable?.isDataTable("#holdst")).to.be
                    .true;
                const table = win.jQuery("#holdst").DataTable();
                expect(table.ready(), "DataTable initialization complete").to.be
                    .true;
                ["call_numbers", "title", "barcodes"].forEach(name => {
                    expect(table.columns(`${name}:name`).count(), name).to.eq(
                        1
                    );
                });
            })
            .then(win => win.jQuery("#holdst").DataTable());

    const isolateFixtures = () =>
        getTable().then(table => {
            table.columns().search("");
            table.column("title:name").visible(true, false);
            table.column("call_numbers:name").visible(true, false);
            table.search(fixtureId).page.len(records.length).draw();
        });

    const assertSort = (mode, direction, afterDraw) =>
        getTable().should(table => {
            expect(table.settings()[0].iDraw, "new draw").to.be.greaterThan(
                afterDraw
            );
            expect(table.order()[0]).to.eql([
                table.column("call_numbers:name").index(),
                direction,
            ]);
            expect(
                table
                    .column("call_numbers:name")
                    .header()
                    .getAttribute("aria-sort")
            ).to.eq(direction === "asc" ? "ascending" : "descending");
            expect(table.rows({ search: "applied" }).count()).to.eq(
                records.length
            );

            const rows = [...table.table().body().querySelectorAll("tr")];
            expect(rows).to.have.length(records.length);
            const rowOrder = rows.map(row => {
                const title = table.cell(row, "title:name").node().textContent;
                const matches = records.filter(record =>
                    title.includes(record.title)
                );
                expect(matches, title).to.have.length(1);
                return records.indexOf(matches[0]);
            });
            expect([...rowOrder].sort()).to.eql([0, 1, 2, 3, 4]);
            // Equal selected keys permit either tie order for the aggregate.
            const tiedRecords = mode === "classification" ? [0, 3] : [1, 3];
            const remainingRecords =
                mode === "classification" ? [1, 2, 4] : [0, 2, 4];
            if (direction === "asc") {
                expect(rowOrder.slice(0, 2)).to.have.members(tiedRecords);
                expect(rowOrder.slice(2)).to.eql(remainingRecords);
            } else {
                expect(rowOrder.slice(0, 3)).to.eql(
                    [...remainingRecords].reverse()
                );
                expect(rowOrder.slice(3)).to.have.members(tiedRecords);
            }

            rows.forEach(row => {
                const title = table.cell(row, "title:name").node().textContent;
                const record = records.find(record =>
                    title.includes(record.title)
                );
                const selectedKey = item =>
                    mode === "alphabetical"
                        ? item.callNumber
                        : (item.sortKey ?? item.callNumber);
                const items = [...record.items].sort((a, b) =>
                    selectedKey(a).localeCompare(selectedKey(b))
                );
                const cell = table.cell(row, "call_numbers:name").node();
                expect(cell.getAttribute("data-order")).to.eq(
                    selectedKey(items[0])
                );
                expect(
                    [...cell.querySelectorAll("li")].map(item =>
                        item.textContent.trim()
                    )
                ).to.eql(items.map(item => item.callNumber));
            });
        });

    const clickCallNumbers = (mode, direction) =>
        getTable().then(table => {
            const draw = table.settings()[0].iDraw;
            cy.wrap(table.column("call_numbers:name").header()).click();
            assertSort(mode, direction, draw);
        });

    ["classification", "alphabetical"].forEach(mode => {
        describe(mode, () => {
            beforeEach(() => {
                cy.login();
                cy.set_syspref(preference, mode);
                cy.visit(reportUrl, {
                    onBeforeLoad(win) {
                        win.localStorage.removeItem(stateKey);
                    },
                });
                isolateFixtures();
                // Start outside call-number ordering, even with a custom default sort.
                getTable().then(table => {
                    const draw = table.settings()[0].iDraw;
                    cy.wrap(table.column("title:name").header()).click();
                    getTable().should(table => {
                        expect(table.settings()[0].iDraw).to.be.greaterThan(
                            draw
                        );
                        expect(table.order()[0][0]).to.eq(
                            table.column("title:name").index()
                        );
                    });
                });
            });

            it("sorts rows and aggregated values by the selected call number key", () => {
                clickCallNumbers(mode, "asc");
                clickCallNumbers(mode, "desc");
            });

            it("sorts after restoring ascending order and a hidden preceding column", () => {
                clickCallNumbers(mode, "asc");
                getTable().then(table => {
                    table.column("barcodes:name").visible(false);
                    table.state.save();
                    // URL state uses the native restore path even when local saving is disabled.
                    const state = table.state();
                    const encodedState = encodeURIComponent(
                        btoa(JSON.stringify(state))
                    );
                    cy.visit(`${reportUrl}&${stateKey}_state=${encodedState}`);
                });
                isolateFixtures();
                getTable().should(table => {
                    expect(table.column("barcodes:name").visible()).to.be.false;
                    expect(table.state.loaded().order[0]).to.eql([
                        "call_numbers",
                        "asc",
                    ]);
                });
                assertSort(mode, "asc", 0);
                clickCallNumbers(mode, "desc");
                clickCallNumbers(mode, "asc");
            });
        });
    });
});
