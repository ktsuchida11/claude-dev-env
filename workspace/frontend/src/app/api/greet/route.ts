import { NextRequest, NextResponse } from "next/server";

export async function GET(request: NextRequest) {
  const name = request.nextUrl.searchParams.get("name") || "World";
  const backendUrl = process.env.BACKEND_URL || "http://backend:8000";

  const res = await fetch(
    `${backendUrl}/api/greet?name=${encodeURIComponent(name)}`,
    { cache: "no-store" }
  );
  const data = await res.json(); // ← ブレークポイントを設定してステップ実行を確認
  return NextResponse.json(data);
}
