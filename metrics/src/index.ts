/// Serves the Sparkle appcast and counts installations on the way past.
///
/// The app's SUFeedURL points here instead of at GitHub Pages, so every update
/// check is also a ping. The feed itself still lives in `docs/appcast.xml` and
/// is fetched from Pages — this Worker never rewrites it, so a release is
/// published exactly as before.
///
/// What is stored: a random UUID the app generates once, the app version, and
/// the macOS version. No IP address, and nothing derived from one.

const UPSTREAM = "https://sembsa.github.io/ContainerDesktop/appcast.xml";

export interface Env {
    DB: D1Database;
    /// `wrangler secret put STATS_TOKEN` — guards /stats so the read allowance
    /// cannot be burned through by anyone who finds the URL.
    STATS_TOKEN?: string;
}

/// Sparkle's default User-Agent is "Container Desktop/0.8.3 Sparkle/2.8.0".
/// That format is Sparkle's choice, not our contract, so the app also sends the
/// version as a feed parameter and this is only the fallback.
function versionFromUserAgent(userAgent: string | null): string | null {
    const match = userAgent?.match(/\/(\d+(?:\.\d+)*)\s+Sparkle\//);
    return match ? match[1] : null;
}

const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const VERSION = /^\d{1,4}(\.\d{1,4}){0,3}$/;

/// Both values arrive from the network, so they are bounded to the shapes the
/// app actually sends. `bind()` already rules out injection; this keeps a bored
/// stranger from filling the table with long strings.
function sanitised(value: string | null, pattern: RegExp): string | null {
    return value && pattern.test(value) ? value : null;
}

/// SQLite generates both timestamps so they always share one format — mixing in
/// a JavaScript ISO string would break the `last_seen > datetime(...)` windows.
async function record(env: Env, id: string, version: string, os: string | null): Promise<void> {
    await env.DB.prepare(
        `INSERT INTO installs (id, version, os, first_seen, last_seen, checks)
         VALUES (?1, ?2, ?3, datetime('now'), datetime('now'), 1)
         ON CONFLICT(id) DO UPDATE SET
             version   = excluded.version,
             os        = COALESCE(excluded.os, installs.os),
             last_seen = datetime('now'),
             checks    = installs.checks + 1`,
    ).bind(id, version, os).run();
}

async function stats(request: Request, env: Env): Promise<Response> {
    const token = env.STATS_TOKEN;
    if (!token || request.headers.get("authorization") !== `Bearer ${token}`) {
        return new Response("unauthorized\n", { status: 401 });
    }

    const window = "last_seen > datetime('now', '-30 day')";
    const [total, active, versions, systems] = await Promise.all([
        env.DB.prepare(`SELECT COUNT(*) AS n FROM installs`).first<{ n: number }>(),
        env.DB.prepare(`SELECT COUNT(*) AS n FROM installs WHERE ${window}`).first<{ n: number }>(),
        env.DB.prepare(
            `SELECT version, COUNT(*) AS n FROM installs WHERE ${window}
             GROUP BY version ORDER BY n DESC`,
        ).all<{ version: string; n: number }>(),
        env.DB.prepare(
            `SELECT COALESCE(os, 'unknown') AS os, COUNT(*) AS n FROM installs WHERE ${window}
             GROUP BY os ORDER BY n DESC`,
        ).all<{ os: string; n: number }>(),
    ]);

    return Response.json({
        installsEver: total?.n ?? 0,
        activeLast30Days: active?.n ?? 0,
        byVersion: versions.results,
        byMacOS: systems.results,
    });
}

export default {
    async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
        const url = new URL(request.url);
        if (url.pathname === "/stats") return stats(request, env);

        const id = sanitised(url.searchParams.get("id"), UUID);
        const version =
            sanitised(url.searchParams.get("v"), VERSION) ??
            sanitised(versionFromUserAgent(request.headers.get("user-agent")), VERSION);
        const os = sanitised(url.searchParams.get("os"), VERSION);

        // The write happens after the response is on its way, and a failure is
        // swallowed: a paused or broken database must never stop an update.
        if (id && version) {
            ctx.waitUntil(
                record(env, id, version, os).catch((error) => {
                    console.error("install upsert failed", error);
                }),
            );
        }

        const upstream = await fetch(UPSTREAM, { cf: { cacheTtl: 300, cacheEverything: true } });
        return new Response(upstream.body, {
            status: upstream.status,
            headers: {
                "content-type": upstream.headers.get("content-type") ?? "application/xml; charset=utf-8",
                "cache-control": "public, max-age=300",
            },
        });
    },
} satisfies ExportedHandler<Env>;
