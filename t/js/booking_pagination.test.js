const test = require("node:test");
const assert = require("node:assert/strict");

global.window = { location: { origin: "http://localhost" } };
const { fetchAllKohaApiPages } = require("../../koha-tmpl/intranet-tmpl/prog/js/modals/booking_pagination.js");

function response(ids, total, resourceKey = "booking_id") {
    return {
        ok: true,
        headers: { get: name => name === "X-Total-Count" ? total : null },
        json: async () => ids.map(id => ({ [resourceKey]: id })),
    };
}

test("collects complete ordered pages and keeps query and embed headers", async () => {
    const pages = [response([1], "3"), response([3], "3"), response([7], "3")];
    const calls = [];
    const rows = await fetchAllKohaApiPages(
        '/api/v1/bookings?_per_page=-1&_page=9&q={"status":"new"}',
        "booking_id",
        { "x-koha-embed": "patron" },
        async (url, options) => {
            calls.push({ url: new URL(url), options });
            return pages.shift();
        }
    );
    assert.deepEqual(rows.map(row => row.booking_id), [1, 3, 7]);
    assert.equal(calls.length, 3);
    calls.forEach(({ url, options }, index) => {
        assert.equal(url.searchParams.get("_page"), String(index + 1));
        assert.equal(url.searchParams.get("_order_by"), "booking_id");
        assert.equal(url.searchParams.get("_per_page"), null);
        assert.equal(url.searchParams.get("q"), '{"status":"new"}');
        assert.equal(options.headers["x-koha-embed"], "patron");
    });
});

test("the complete-set helper handles item and checkout resources", async () => {
    for (const key of ["item_id", "checkout_id"]) {
        const pages = [response([1], "2", key), response([2], "2", key)];
        const rows = await fetchAllKohaApiPages(
            "/api/v1/resources", key, {}, async () => pages.shift()
        );
        assert.deepEqual(rows.map(row => row[key]), [1, 2]);
    }
});

test("accepts an empty collection", async () => {
    const rows = await fetchAllKohaApiPages(
        "/api/v1/bookings", "booking_id", {}, async () => response([], "0")
    );
    assert.deepEqual(rows, []);
});

for (const [name, pages, message] of [
    ["missing count", [response([], null)], /Invalid or excessive/],
    ["changed count", [response([1], "2"), response([2], "3")], /count changed/],
    ["repeated page", [response([1], "3"), response([1], "3")], /did not advance/],
    ["empty middle page", [response([1], "2"), response([], "2")], /Incomplete or inconsistent/],
    ["rows beyond count", [response([1], "0")], /Incomplete or inconsistent/],
]) {
    test(`rejects ${name} without returning a partial set`, async () => {
        let index = 0;
        await assert.rejects(
            fetchAllKohaApiPages(
                "/api/v1/bookings", "booking_id", {}, async () => pages[index++]
            ),
            message
        );
    });
}

test("rejects an HTTP failure", async () => {
    await assert.rejects(
        fetchAllKohaApiPages(
            "/api/v1/bookings", "booking_id", {}, async () => ({ ok: false, statusText: "Unavailable" })
        ),
        /Unavailable/
    );
});
