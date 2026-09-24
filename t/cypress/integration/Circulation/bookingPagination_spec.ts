describe("Booking complete-set pagination", () => {
    let fetchPages;
    let requests;
    let responses;

    beforeEach(() => {
        requests = [];
        responses = [];
        cy.readFile(
            "koha-tmpl/intranet-tmpl/prog/js/modals/place_booking.js"
        ).then(source => {
            // Execute the production helper, without initializing the modal.
            const start = source.indexOf(
                "async function fetchAllKohaApiPages("
            );
            expect(start).to.be.greaterThan(-1);
            const end = source.indexOf("\n/**", start);
            expect(end).to.be.greaterThan(start);
            fetchPages = new Function(
                "window",
                "fetch",
                `${source.slice(start, end)}; return fetchAllKohaApiPages;`
            )(
                { location: { origin: "http://localhost" } },
                async (url, options) => {
                    requests.push({ url: new URL(url), options });
                    const response = responses.shift();
                    expect(response, "unexpected additional page request").to
                        .exist;
                    return {
                        ok: response.ok ?? true,
                        statusText: "Request failed",
                        json: async () => response.body,
                        headers: {
                            get: name =>
                                name === "X-Total-Count"
                                    ? (response.total ?? null)
                                    : null,
                        },
                    };
                }
            );
        });
    });

    const reject = message =>
        fetchPages("/api/v1/bookings", "booking_id").then(
            () => {
                throw new Error("An incomplete result must not be accepted");
            },
            error => expect(error.message).to.contain(message)
        );

    ["item_id", "booking_id", "checkout_id"].forEach(key => {
        it(`retrieves single-row pages in stable ${key} order`, () => {
            responses = [1, 3, 7].map(id => ({
                body: [{ [key]: id }],
                total: "3",
            }));
            return fetchPages(
                '/api/v1/bookings?_per_page=-1&_page=9&q={"status":"new"}',
                key,
                { "x-koha-embed": "patron" }
            ).then(records => {
                expect(records.map(record => record[key])).to.deep.equal([
                    1, 3, 7,
                ]);
                expect(requests).to.have.length(3);
                requests.forEach(({ url, options }, index) => {
                    expect(url.searchParams.get("_page")).to.equal(
                        `${index + 1}`
                    );
                    expect(url.searchParams.get("_order_by")).to.equal(key);
                    expect(url.searchParams.has("_per_page")).to.equal(false);
                    expect(url.searchParams.get("q")).to.equal(
                        '{"status":"new"}'
                    );
                    expect(options.headers["x-koha-embed"]).to.equal("patron");
                });
            });
        });
    });

    it("accepts a genuinely empty collection", () => {
        responses = [{ body: [], total: "0" }];
        return fetchPages("/api/v1/bookings", "booking_id").then(records => {
            expect(records).to.deep.equal([]);
            expect(requests).to.have.length(1);
        });
    });

    [null, "", "-1", "1.5", "NaN", "4e0", "10001", "9007199254740992"].forEach(
        total => {
            it(`rejects missing, invalid or excessive total ${total}`, () => {
                responses = [{ body: [], total }];
                return reject("Invalid or excessive");
            });
        }
    );

    [
        { label: "repeated page", first: [1, 2], second: [1, 2] },
        { label: "overlapping page", first: [1, 2], second: [2, 3] },
        { label: "duplicate within a page", first: [1, 1], second: [] },
        { label: "out-of-order results", first: [2, 1], second: [] },
        { label: "missing resource key", first: [undefined], second: [] },
        { label: "invalid resource key", first: [0], second: [] },
    ].forEach(({ label, first, second }) => {
        it(`rejects ${label} without returning partial availability`, () => {
            responses = [first, second].map(ids => ({
                body: ids.map(booking_id => ({ booking_id })),
                total: "4",
            }));
            return reject("did not advance");
        });
    });

    it("rejects a changing collection count", () => {
        responses = [
            { body: [{ booking_id: 1 }], total: "2" },
            { body: [{ booking_id: 2 }], total: "3" },
        ];
        return reject("count changed");
    });

    it("rejects an empty page before the advertised total", () => {
        responses = [
            { body: [{ booking_id: 1 }], total: "2" },
            { body: [], total: "2" },
        ];
        return reject("Incomplete or inconsistent");
    });

    it("rejects rows beyond the advertised total", () => {
        responses = [{ body: [{ booking_id: 1 }], total: "0" }];
        return reject("Incomplete or inconsistent");
    });

    it("bounds the number of requests even when every page advances", () => {
        responses = Array.from({ length: 1000 }, (_, index) => ({
            body: [{ booking_id: index + 1 }],
            total: "1001",
        }));
        return reject("exceeded the page limit").then(() => {
            expect(requests).to.have.length(1000);
        });
    });

    it("rejects an HTTP failure", () => {
        responses = [{ ok: false }];
        return reject("Request failed");
    });

    it("rejects a non-array API response", () => {
        responses = [{ body: {}, total: "0" }];
        return reject("Expected a paginated");
    });
});
