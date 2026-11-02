// config/notify/notify.json (decision 9). It holds env variable names, never a value. The file
// channel is always present, as in full/config/notify.json.
import type { Answers, Channel } from "./answers.ts";
import { ASSETS } from "./services.ts";

type Json = string | number | boolean | Json[] | { [key: string]: Json };
type JsonMap = { [key: string]: Json };

export const FILE_CHANNEL: JsonMap = { id: "log", type: "file", path: "/data/incidents.jsonl" };

function demoMail(statusUrl: string | undefined): JsonMap {
  const doc = JSON.parse(ASSETS.demoNotify) as { channels: JsonMap[] };
  const mail = doc.channels.find((c) => c.id === "mail");
  if (mail === undefined) throw new Error("demo/notify.json: has no mail channel");
  const rest: JsonMap = { ...mail };
  delete rest.statusUrl;
  return statusUrl === undefined ? rest : { ...rest, statusUrl };
}

function channelJson(channel: Channel, statusUrl: string | undefined): JsonMap {
  switch (channel.type) {
    case "demo-mail":
      return demoMail(statusUrl);
    case "email": {
      const smtp: JsonMap = {
        host: channel.smtpHost,
        port: channel.smtpPort,
        tls: channel.smtpTls,
      };
      if (channel.smtpUser !== undefined) smtp.username = channel.smtpUser;
      if (channel.smtpPasswordEnv !== undefined) smtp.passwordEnv = channel.smtpPasswordEnv;
      const mail: JsonMap = {
        id: "mail",
        type: "email",
        smtp,
        from: channel.mailFrom,
        to: [...channel.mailTo],
        subjectPrefix: channel.subjectPrefix,
      };
      if (statusUrl !== undefined) mail.statusUrl = statusUrl;
      return mail;
    }
    case "webhook": {
      const hook: JsonMap = { id: "hook", type: "webhook", url: channel.url };
      if (channel.secretEnv !== undefined) hook.secretEnv = channel.secretEnv;
      return hook;
    }
  }
}

type NotifyAnswers = Pick<Answers, "notify" | "status" | "channels" | "urls">;

/** The text of config/notify/notify.json, or undefined when notify is off. */
export function renderNotify(answers: NotifyAnswers): string | undefined {
  if (!answers.notify) return undefined;
  const statusUrl = answers.status ? answers.urls.status : undefined;
  const channels = [FILE_CHANNEL, ...answers.channels.map((c) => channelJson(c, statusUrl))];
  return `${JSON.stringify({ channels }, null, 2)}\n`;
}

/** The env variable names that the channels reference, in order, each once. */
export function notifyEnvNames(answers: Pick<Answers, "notify" | "channels">): string[] {
  if (!answers.notify) return [];
  const names: string[] = [];
  for (const c of answers.channels) {
    let name: string | undefined;
    if (c.type === "email") name = c.smtpPasswordEnv;
    if (c.type === "webhook") name = c.secretEnv;
    if (name !== undefined && !names.includes(name)) names.push(name);
  }
  return names;
}
