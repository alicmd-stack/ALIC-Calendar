/**
 * Turn a PostgREST error into a real Error.
 *
 * WHY THIS EXISTS
 * ---------------
 * `const { data, error } = await supabase.rpc(...)` puts a PLAIN OBJECT in
 * `error`, not an Error instance — postgrest-js only constructs a real
 * `PostgrestError` when `.throwOnError()` was used, and nothing here does.
 * So the idiomatic-looking `if (error) throw error` threw an object, and every
 * downstream `err instanceof Error ? err.message : String(err)` fell to
 * `String(err)`, which is the literal string `"[object Object]"`.
 *
 * That silently disabled every error branch in the station: the amber
 * "room is full" dialog could never open because its trigger tests the message
 * for `room_at_capacity`, so a full classroom turned a child away behind a
 * modal reading "[object Object]". The same failure hid the real reason for
 * every other station error.
 *
 * Callers get an Error whose `message` is the database's message and whose
 * `code` is the SQLSTATE, so they can branch on either.
 */

export interface RpcErrorShape {
  message?: string;
  code?: string;
  details?: string | null;
  hint?: string | null;
}

/** An Error carrying the database's SQLSTATE and hint. */
export class RpcError extends Error {
  readonly code?: string;
  readonly details?: string | null;
  readonly hint?: string | null;

  constructor(shape: RpcErrorShape) {
    super(shape.message || "The database rejected the request");
    this.name = "RpcError";
    this.code = shape.code;
    this.details = shape.details ?? null;
    this.hint = shape.hint ?? null;
  }
}

/**
 * Throw `error` as a real Error if it is set. Pass the value straight from a
 * destructured supabase response.
 */
export function throwRpc(error: RpcErrorShape | null | undefined): void {
  if (!error) return;
  throw new RpcError(error);
}

/**
 * The message from anything that was thrown, without the `[object Object]`
 * trap. Safe on Errors, on bare PostgREST objects, and on strings.
 */
export function errorMessage(err: unknown): string {
  if (err instanceof Error) return err.message;
  if (typeof err === "string") return err;
  if (err && typeof err === "object") {
    const shape = err as RpcErrorShape;
    if (typeof shape.message === "string") return shape.message;
  }
  return String(err);
}

/** The SQLSTATE, when the thrown value carries one. */
export function errorCode(err: unknown): string | undefined {
  if (err && typeof err === "object" && "code" in err) {
    const code = (err as RpcErrorShape).code;
    return typeof code === "string" ? code : undefined;
  }
  return undefined;
}

/**
 * Does this failure carry a specific database error? Matches the message
 * rather than the SQLSTATE because plpgsql `RAISE EXCEPTION 'name'` without an
 * ERRCODE reports P0001 for every one of them — the name IS the message.
 */
export function isDbError(err: unknown, name: string): boolean {
  return errorMessage(err).includes(name);
}
