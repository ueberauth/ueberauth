import { isPrerelease } from 'verkit';
/**
 * Format arguments.
 * @param args
 * @returns Formatted arguments.
 */
export function formatArgs(...args) {
    return args.reduce((finalArgs, arg) => {
        if (arg) {
            finalArgs.push(String(arg));
        }
        return finalArgs;
    }, []);
}
/**
 * Convert value to array.
 * @param value
 * @returns Array.
 */
export function toArray(value) {
    return Array.isArray(value) ? value : [value];
}
/**
 * Check if version is a prerelease, e.g. 1.0.0-alpha.1, 1.0.0-rc.2.
 * @param version
 * @returns True if version is a prerelease.
 */
export function isPrereleaseVersion(version) {
    return isPrerelease(version) === true;
}
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoidXRpbHMuanMiLCJzb3VyY2VSb290IjoiIiwic291cmNlcyI6WyIuLi9zcmMvdXRpbHMudHMiXSwibmFtZXMiOltdLCJtYXBwaW5ncyI6IkFBQUEsT0FBTyxFQUFFLFlBQVksRUFBRSxNQUFNLFFBQVEsQ0FBQTtBQUdyQzs7OztHQUlHO0FBQ0gsTUFBTSxVQUFVLFVBQVUsQ0FBQyxHQUFHLElBQVc7SUFDdkMsT0FBTyxJQUFJLENBQUMsTUFBTSxDQUFXLENBQUMsU0FBUyxFQUFFLEdBQUcsRUFBRSxFQUFFO1FBQzlDLElBQUksR0FBRyxFQUFFLENBQUM7WUFDUixTQUFTLENBQUMsSUFBSSxDQUFDLE1BQU0sQ0FBQyxHQUFHLENBQUMsQ0FBQyxDQUFBO1FBQzdCLENBQUM7UUFFRCxPQUFPLFNBQVMsQ0FBQTtJQUNsQixDQUFDLEVBQUUsRUFBRSxDQUFDLENBQUE7QUFDUixDQUFDO0FBRUQ7Ozs7R0FJRztBQUNILE1BQU0sVUFBVSxPQUFPLENBQUksS0FBYztJQUN2QyxPQUFPLEtBQUssQ0FBQyxPQUFPLENBQUMsS0FBSyxDQUFDLENBQUMsQ0FBQyxDQUFDLEtBQUssQ0FBQyxDQUFDLENBQUMsQ0FBQyxLQUFLLENBQUMsQ0FBQTtBQUMvQyxDQUFDO0FBRUQ7Ozs7R0FJRztBQUNILE1BQU0sVUFBVSxtQkFBbUIsQ0FBQyxPQUFlO0lBQ2pELE9BQU8sWUFBWSxDQUFDLE9BQU8sQ0FBQyxLQUFLLElBQUksQ0FBQTtBQUN2QyxDQUFDIn0=