// Types of the text imports (`with { type: "text" }`) of cli/services.ts: each is the file content.
declare module "*.yaml" {
  const text: string;
  export default text;
}
declare module "*.sh" {
  const text: string;
  export default text;
}
