[% USE raw %]
[% USE AdditionalContents %]
[% SET CatalogConcernHelp = AdditionalContents.get( location => "CatalogConcernHelp", lang => lang, library => logged_in_user.branchcode || default_branch ) %]
[% SET CatalogConcernTemplate = AdditionalContents.get( location => "CatalogConcernTemplate", lang => lang, library => logged_in_user.branchcode || default_branch ) %]
<!-- Add concern modal -->
<div class="modal" id="addConcernModal" tabindex="-1" role="dialog" aria-labelledby="addConcernModalLabel" aria-hidden="true">
    <div class="modal-dialog modal-lg">
        <div class="modal-content">
            <div class="modal-header">
                <h1 class="modal-title" id="addConcernModalLabel">Report a concern</h1>
                <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button>
            </div>
            <div class="modal-body">
                <fieldset id="concern_fieldset">
                    <div class="form-group">
                        <label for="concern_title">Title: </label>
                        <input type="text" name="concern_title" id="concern_title" required="required" />
                    </div>
                    <div class="form-group">
                        <label for="concern_body">Please describe your concerns: </label>
                        <textarea class="form-control" name="concern_body" id="concern_body" aria-describedby="helpBlock" required="required" rows="15"></textarea>
                        [%- IF CatalogConcernHelp && CatalogConcernHelp.content && CatalogConcernHelp.content.count > 0 -%]
                            <div class="help-block">
                                [%- FOREACH help IN CatalogConcernHelp.content -%]
                                    [%- help.content | $raw -%]
                                [%- END -%]
                            </div>
                        [%- END -%]
                        <div id="concern_template" style="display: none;">
                            [%- IF CatalogConcernTemplate && CatalogConcernTemplate.content && CatalogConcernTemplate.content.count > 0 -%]
                                [%- FOREACH template IN CatalogConcernTemplate.content -%]
                                    [%- template.content | $raw -%]
                                [%- END -%]
                            [%- END -%]
                        </div>
                    </div>
                </fieldset>
            </div>
            <div class="modal-footer">
                <input type="hidden" name="biblio_id" id="concern_biblio" value="[% biblio.biblionumber | html %]" />
                <input type="hidden" name="reporter_id" id="concern_reporter" value="[% borrowernumber | html %]" />
                <button type="submit" id="addConfirm" class="btn btn-primary">Submit <i id="concern-submit-spinner" class="fa fa-spinner fa-pulse fa-fw" style="display:none"></i></button>
                <button type="button" class="btn btn-default" data-bs-dismiss="modal">Cancel</button>
            </div>
        </div>
    </div>
</div>
