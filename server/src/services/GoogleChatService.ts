import type { AppEnv } from "../config/env.js";

export class GoogleChatService {
  constructor(private readonly appEnv: AppEnv) {}

  async sendOtp(params: {
    userEmail: string;
    userId: string;
    userWallet: string;
    otp: string;
    expiresAt: string;
  }): Promise<void> {
    if (!this.appEnv.GOOGLE_CHAT_WEBHOOK_URL) {
      throw new Error("Google Chat configuration is incomplete. Set GOOGLE_CHAT_WEBHOOK_URL.");
    }

    const response = await fetch(this.appEnv.GOOGLE_CHAT_WEBHOOK_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
      },
      body: JSON.stringify({
        text: [
          "Granite Lake verification code",
          "",
          `User email: ${params.userEmail}`,
          `User ID: ${params.userId}`,
          `User wallet: ${params.userWallet}`,
          `OTP: ${params.otp}`,
          `Expires at: ${params.expiresAt}`,
          "",
          "Use this code to finish verifying the wallet for this domain.",
        ].join("\n"),
      }),
    });

    if (!response.ok) {
      const message = await response.text();
      throw new Error(message || "Google Chat failed to send OTP message.");
    }
  }
}
