/* global $ */
$(document).ready(function () {
    const source = document.getElementById("data_source");
    if (!source) return;

    function updateSource() {
        const pseudo = source.value === "pseudonymized";
        $(".pseudonymized-source-help").toggleClass("d-none", !pseudo);
        const bibliography = document.getElementById("cellvalue5");
        bibliography.disabled = pseudo;
        if (pseudo && bibliography.checked) {
            document.getElementById("cellvalue1").checked = true;
        }
        const localuse = document.querySelector(
            "#PeriodTypeSel option[value='localuse']"
        );
        localuse.disabled = pseudo;
        if (pseudo && localuse.selected) {
            document.getElementById("PeriodTypeSel").value = "issue";
        }
        $("tr.patron-attribute").each(function () {
            const unavailable = pseudo && this.dataset.retained !== "1";
            $(this).toggle(!unavailable);
            $(this).find("input,select").prop("disabled", unavailable);
            if (unavailable) {
                $(this)
                    .find("input[type=radio]:checked")
                    .each(function () {
                        const fallback =
                            this.name === "Line" ? "branch" : "itemtype";
                        document.querySelector(
                            `input[name='${this.name}'][value='${fallback}']`
                        ).checked = true;
                    });
            }
        });
    }
    source.addEventListener("change", updateSource);
    updateSource();
});
