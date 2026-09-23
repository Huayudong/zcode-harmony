import { z } from "./zod-ambient";
import type { CuaPermissionKind } from "./cuaAccessibilitySettings.js";
import { timestampSchema } from "./core.js";

export const cuaRequestAccessStatusSchema = z
  .object({
    schemaVersion: z.literal(1),
    platform: z.literal("darwin"),
    grantOwner: z.string().min(1),
    accessibility: z.enum(["granted", "stale", "denied"]),
    screenRecording: z.enum(["granted", "denied", "unknown"]),
  })
  .strict();
export type CuaRequestAccessStatus = any;

export function requiredCuaPermissionsForRequestAccessStatus(
  status: CuaRequestAccessStatus,
): CuaPermissionKind[] {
  const required: CuaPermissionKind[] = [];
  if (status.accessibility === "denied" || status.accessibility === "stale") {
    required.push("accessibility");
  }
  if (status.screenRecording === "denied") {
    required.push("screen_recording");
  }
  return required;
}

export const cuaPermissionObservationSchema = z
  .object({
    schemaVersion: z.literal(1),
    eventId: z.string().min(1),
    eventSeq: z.number().int().nonnegative(),
    occurredAt: timestampSchema,
    sessionId: z.string().min(1),
    turnId: z.string().min(1).optional(),
    toolCallId: z.string().min(1),
    permissionStatus: cuaRequestAccessStatusSchema,
  })
  .strict();
export type CuaPermissionObservation = any;
