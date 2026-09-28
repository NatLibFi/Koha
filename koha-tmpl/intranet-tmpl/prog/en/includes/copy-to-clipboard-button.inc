[% SET label = label.defined ? label : 'Copy to clipboard' %]
[% SET btn_class = class.defined ? class : 'btn btn-xs btn-primary' %]
[% SET value = value.defined ? value : copy_to_clipboard_value %]
<button type="button" class="[% btn_class | html %]" data-bs-placement="right" data-bs-delay='{"show":0,"hide":2000}' data-copy-to-clipboard data-value="[% value | html %]" title="Copy to clipboard">
    <i class="fa-solid fa-clipboard"></i> [% label | html %]
</button>
