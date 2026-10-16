[% USE raw %]
<!-- slip-print.inc -->
<script nonce="[% Koha.CSPNonce | $raw %]">
    [% IF ( Koha.Preference('IntranetSlipPrinterJS') ) %]
        let autoprint = false;
        [% Koha.Preference('IntranetSlipPrinterJS') | $raw %]
    [% ELSE %]
        let autoprint = true;
        // Register before printing: window.print() may dispatch afterprint
        // before it returns, so a handler added afterwards never runs.
        window.addEventListener('afterprint', function () {
            setTimeout(function () {
                window.close();
            }, 100);
        });
        window.addEventListener('load', function() {
            window.print();
        });
    [% END %]
</script>
<!-- / slip-print.inc -->
