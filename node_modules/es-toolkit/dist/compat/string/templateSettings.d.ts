import { escape } from "./escape.js";
import { template } from "./template.js";
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