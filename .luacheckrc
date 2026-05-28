globals = {
    "vim",
}
-- Don't lint build outputs / vendored trees.
exclude_files = {
    "result",
    "result/**",
    ".direnv/**",
    "core/target/**",
}
-- Ignore some common false positives if necessary
-- ignore = { "631" } -- line is too long
