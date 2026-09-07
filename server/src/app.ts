import { randomUUID } from "node:crypto";
import Fastify, { type FastifyError } from "fastify";
import rateLimit from "@fastify/rate-limit";
import { adminRoutes } from "./routes/admin.js";
import { healthRoutes } from "./routes/health.js";
import { otpRoutes } from "./routes/otp.js";

// Libraries like undici and protobuf-ts wrap the real errno-level failure
// (ECONNRESET, ETIMEDOUT, ...) several `.cause` levels deep behind a generic
// message ("fetch failed"). Pino's default err serializer doesn't unwrap it,
// so surface the chain explicitly to make network failures diagnosable.
function serializeCauseChain(error: unknown, maxDepth = 5): Array<Record<string, unknown>> {
  const chain: Array<Record<string, unknown>> = [];
  let current = error instanceof Error ? (error as { cause?: unknown }).cause : undefined;

  while (current instanceof Error && chain.length < maxDepth) {
    chain.push({
      name: current.name,
      message: current.message,
      code: (current as NodeJS.ErrnoException).code,
    });
    current = (current as { cause?: unknown }).cause;
  }

  return chain;
}

export async function buildApp() {
  const app = Fastify({
    logger: true,
  });

  // Every route handles its own expected error cases and responds directly;
  // anything that reaches this handler is an unmapped condition (a bug, an
  // unexpected dependency failure, a framework-level parsing error). Without
  // this, Fastify's default handler serializes the raw error — including
  // internal messages and, for framework-level failures, the framework's own
  // error codes — straight to an unauthenticated caller.
  app.setErrorHandler((error: FastifyError, request, reply) => {
    const correlationId = randomUUID();
    request.log.error({ err: error, causeChain: serializeCauseChain(error), correlationId }, "Unhandled request error");

    const statusCode =
      typeof error.statusCode === "number" && error.statusCode >= 400 && error.statusCode < 600
        ? error.statusCode
        : 500;
    const isClientError = statusCode < 500;

    return reply.status(statusCode).send({
      error: isClientError ? "bad_request" : "internal_error",
      message: isClientError ? "The request could not be processed." : "An unexpected error occurred.",
      correlationId,
    });
  });

  await app.register(rateLimit, {
    max: 100,
    timeWindow: "1 minute",
  });

  await app.register(healthRoutes);
  await app.register(adminRoutes);
  await app.register(otpRoutes);

  return app;
}
