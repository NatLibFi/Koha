<fieldset class="acqui_basket_add">
    <legend class="sr-only">Add order to basket</legend>
    [% IF has_budgets %]
        <ul>
            <li>
                <form action="/cgi-bin/koha/catalogue/search.pl" method="get">
                    <label
                        >From an existing record:
                        <input type="text" name="q" size="25" />
                    </label>
                    <input type="submit" class="submit" id="searchtoorder" data-booksellerid="[% booksellerid | html %]" data-basketno="[% basketno | html %]" value="Submit" />
                </form>
            </li>
            <li><a href="/cgi-bin/koha/acqui/newordersuggestion.pl?booksellerid=[% booksellerid | uri %]&amp;basketno=[% basketno | uri %]">From a suggestion</a></li>
            <li><a href="/cgi-bin/koha/acqui/newordersubscription.pl?booksellerid=[% booksellerid | uri %]&amp;basketno=[% basketno | uri %]">From a subscription</a></li>
            <li><a href="/cgi-bin/koha/acqui/neworderempty.pl?booksellerid=[% booksellerid | uri %]&amp;basketno=[% basketno | uri %]">From a new (empty) record</a></li>
            <li><a href="/cgi-bin/koha/acqui/duplicate_orders.pl?basketno=[% basketno | uri %]">From existing orders (copy)</a></li>
            <li><a href="/cgi-bin/koha/acqui/z3950_search.pl?booksellerid=[% booksellerid | uri %]&amp;basketno=[% basketno | uri %]">From an external source</a></li>
            [% IF ( CAN_user_tools_stage_marc_import ) %]<li><a href="/cgi-bin/koha/tools/stage-marc-import.pl?basketno=[% basketno | uri %]&amp;booksellerid=[% booksellerid | uri %]"> From a new file</a></li>[% END %]
            <li><a href="/cgi-bin/koha/acqui/addorderiso2709.pl?booksellerid=[% booksellerid | uri %]&amp;basketno=[% basketno | uri %]"> From a staged file</a></li>
            [% IF ( CAN_user_circulate ) %]<li><a href="/cgi-bin/koha/circ/reserveratios.pl?booksellerid=[% booksellerid | uri %]&amp;basketno=[% basketno | uri %]">From titles with highest hold ratios</a></li>[% END %]
        </ul>
    [% ELSE %]
        <div class="alert alert-warning">
            <p>You can't create any orders unless you first <a href="/cgi-bin/koha/admin/aqbudgetperiods.pl">define a budget and a fund</a>.</p>
        </div>
    [% END %]
</fieldset>
