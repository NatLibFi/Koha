<template>
    <input type="submit" class="btn btn-primary" :value="text" />
</template>

<script>
export default {
    name: "ButtonSubmit",
    props: {
        text: {
            type: String,
            default: __("Submit"),
            required: false,
        },
    },
};
</script>
