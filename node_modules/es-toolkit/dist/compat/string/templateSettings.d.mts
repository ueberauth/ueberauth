import { escape } from "./escape.mjs";
import { template } from "./template.mjs";
export declare const templateSettings: {
  escape: RegExp;
  evaluate: RegExp;
  interpolate: RegExp;
  variable: string;
  imports: {
    _: {
      escape: typeof escape;
      template: typeof template;
    };
  };
};