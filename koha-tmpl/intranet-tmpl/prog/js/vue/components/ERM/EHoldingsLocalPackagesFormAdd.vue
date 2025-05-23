<template>
    <div v-if="!initialized">{{ $__("Loading") }}</div>
    <div v-else id="packages_add">
        <h2 v-if="erm_package.package_id">
            {{ $__("Edit package #%s").format(erm_package.package_id) }}
        </h2>
        <h2 v-else>{{ $__("New package") }}</h2>
        <div>
            <form @submit="onSubmit($event)">
                <fieldset class="rows">
                    <ol>
                        <li>
                            <label class="required" for="package_name"
                                >{{ $__("Package name") }}:</label
                            >
                            <input
                                id="package_name"
                                v-model="erm_package.name"
                                :placeholder="$__('Package name')"
                                required
                            />
                            <span class="required">{{ $__("Required") }}</span>
                        </li>
                        <li>
                            <label for="package_vendor_id"
                                >{{ $__("Vendor") }}:</label
                            >
                            <FormSelectVendors
                                id="package_vendor_id"
                                v-model="erm_package.vendor_id"
                            />
                        </li>
                        <li>
                            <label for="package_type">{{ $__("Type") }}:</label>
                            <v-select
                                id="package_type"
                                v-model="erm_package.package_type"
                                label="description"
                                :reduce="av => av.value"
                                :options="authorisedValues.av_package_types"
                            />
                        </li>
                        <li>
                            <label for="package_content_type">{{
                                $__("Content type: ")
                            }}</label>
                            <v-select
                                id="package_content_type"
                                v-model="erm_package.content_type"
                                label="description"
                                :reduce="av => av.value"
                                :options="
                                    authorisedValues.av_package_content_types
                                "
                            />
                        </li>
                        <li>
                            <label for="package_notes"
                                >{{ $__("Notes") }}:</label
                            >
                            <textarea
                                id="package_notes"
                                v-model="erm_package.notes"
                            />
                        </li>
                    </ol>
                </fieldset>
                <AdditionalFieldsEntry
                    resource_type="package"
                    :additional_field_values="erm_package.extended_attributes"
                    @additional-fields-changed="additionalFieldsChanged"
                />
                <EHoldingsPackageAgreements
                    :package_agreements="erm_package.package_agreements"
                />
                <fieldset class="action">
                    <input
                        type="submit"
                        class="btn btn-primary"
                        :value="$__('Submit')"
                    />
                    <router-link
                        :to="{ name: 'EHoldingsLocalPackagesList' }"
                        role="button"
                        class="cancel"
                        >{{ $__("Cancel") }}</router-link
                    >
                </fieldset>
            </form>
        </div>
    </div>
</template>

<script>
import { inject } from "vue";
import EHoldingsPackageAgreements from "./EHoldingsLocalPackageAgreements.vue";
import AdditionalFieldsEntry from "../AdditionalFieldsEntry.vue";
import FormSelectVendors from "../FormSelectVendors.vue";
import { setMessage, setError, setWarning } from "../../messages";
import { APIClient } from "../../fetch/api-client.js";
import { storeToRefs } from "pinia";

export default {
    setup() {
        const ERMStore = inject("ERMStore");
        const { authorisedValues } = storeToRefs(ERMStore);

        return {
            authorisedValues,
        };
    },
    data() {
        return {
            erm_package: {
                package_id: null,
                vendor_id: null,
                name: "",
                external_id: "",
                package_type: "",
                content_type: "",
                notes: "",
                created_on: null,
                resources: null,
                package_agreements: [],
                extended_attributes: [],
            },
            initialized: false,
        };
    },
    beforeRouteEnter(to, from, next) {
        next(vm => {
            if (to.params.package_id) {
                vm.erm_package = vm.getPackage(to.params.package_id);
            } else {
                vm.initialized = true;
            }
        });
    },
    methods: {
        getPackage(package_id) {
            const client = APIClient.erm;
            client.localPackages.get(package_id).then(
                erm_package => {
                    this.erm_package = erm_package;
                    this.initialized = true;
                },
                error => {}
            );
        },
        checkForm(erm_package) {
            let errors = [];
            let package_agreements = erm_package.package_agreements;
            const agreement_ids = package_agreements.map(pa => pa.agreement_id);
            const duplicate_agreement_ids = agreement_ids.filter(
                (id, i) => agreement_ids.indexOf(id) !== i
            );

            if (duplicate_agreement_ids.length) {
                errors.push(this.$__("An agreement is used several times"));
            }

            errors.forEach(function (e) {
                setWarning(e);
            });
            return !errors.length;
        },
        onSubmit(e) {
            e.preventDefault();

            let erm_package = JSON.parse(JSON.stringify(this.erm_package)); // copy

            if (!this.checkForm(erm_package)) {
                return false;
            }

            let package_id = erm_package.package_id;
            delete erm_package.package_id;
            delete erm_package.resources;
            delete erm_package.vendor;
            delete erm_package.resources_count;
            delete erm_package.is_selected;
            delete erm_package._strings;

            erm_package.package_agreements = erm_package.package_agreements.map(
                ({ package_id, agreement, ...keepAttrs }) => keepAttrs
            );

            const client = APIClient.erm;
            if (package_id) {
                client.localPackages.update(erm_package, package_id).then(
                    success => {
                        setMessage(this.$__("Package updated"));
                        this.$router.push({
                            name: "EHoldingsLocalPackagesList",
                        });
                    },
                    error => {}
                );
            } else {
                client.localPackages.create(erm_package).then(
                    success => {
                        setMessage(this.$__("Package created"));
                        this.$router.push({
                            name: "EHoldingsLocalPackagesList",
                        });
                    },
                    error => {}
                );
            }
        },
        additionalFieldsChanged(additionalFieldValues) {
            this.erm_package.extended_attributes = additionalFieldValues;
        },
    },
    components: {
        EHoldingsPackageAgreements,
        FormSelectVendors,
        AdditionalFieldsEntry,
    },
    name: "EHoldingsEBSCOPackagesFormAdd",
};
</script>
