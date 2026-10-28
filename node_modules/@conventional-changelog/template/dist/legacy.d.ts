/**
 * Creates writer options which make legacy handlebars-based writers
 * (`conventional-changelog-writer@8` and older) fail loudly instead of
 * silently rendering an empty changelog when a mixed-versions install
 * resolves a modern preset against them.
 * Legacy writers compile the `mainTemplate` option with handlebars,
 * where rendering the planted template triggers the `helperMissing` hook,
 * which throws an error with the message from the template.
 * Modern writers have no `mainTemplate` option and ignore the value,
 * and a string survives the option merges of downstream tooling,
 * so the guard reaches legacy writers even through cloned options.
 * The message must not contain `]` characters to stay a valid
 * handlebars segment literal.
 * @param preset - Preset package name to mention in the error message.
 * @returns Writer options to spread into preset writer options.
 */
export declare function createLegacyWriterGuard(preset: string): {
    mainTemplate: string;
};
//# sourceMappingURL=legacy.d.ts.map