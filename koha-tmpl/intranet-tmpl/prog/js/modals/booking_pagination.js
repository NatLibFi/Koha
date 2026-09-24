async function fetchAllKohaApiPages(endpoint, resourceKey, headers = {}, fetchPage = fetch) {
    // Bound complete-set calculations independently of each API page's limit.
    const maxRecords = 10000;
    const maxPages = 1000;
    const records = [];
    const url = new URL(endpoint, window.location.origin);
    url.searchParams.delete("_per_page");
    url.searchParams.set("_order_by", resourceKey);
    let expectedTotal;
    let previousId = 0;

    for (let page = 1; page <= maxPages; page++) {
        url.searchParams.set("_page", page);
        const response = await fetchPage(url, { headers });
        if (!response.ok) {
            throw new Error(response.statusText || "API request failed");
        }

        const pageRecords = await response.json();
        if (!Array.isArray(pageRecords)) {
            throw new Error("Expected a paginated API response");
        }

        const totalHeader = response.headers.get("X-Total-Count");
        const total = Number(totalHeader);
        if (
            totalHeader === null ||
            !/^\d+$/.test(totalHeader) ||
            !Number.isSafeInteger(total) ||
            total > maxRecords
        ) {
            throw new Error("Invalid or excessive API result count");
        }
        expectedTotal ??= total;
        if (total !== expectedTotal) {
            throw new Error("API result count changed during pagination");
        }
        if (
            records.length + pageRecords.length > total ||
            (pageRecords.length === 0 && records.length < total)
        ) {
            throw new Error("Incomplete or inconsistent API pagination");
        }
        for (const record of pageRecords) {
            const id = record?.[resourceKey];
            if (!Number.isSafeInteger(id) || id <= previousId) {
                throw new Error(
                    "API pagination did not advance in resource order"
                );
            }
            previousId = id;
            records.push(record);
        }
        if (records.length === total) {
            return records;
        }
    }
    throw new Error("API pagination exceeded the page limit");
}


// The same production function is imported by the Cypress behavior tests.
if (typeof module !== "undefined" && module.exports) {
    module.exports = { fetchAllKohaApiPages };
}
