"use server";

export async function greetAction(name: string) {
  const backendUrl = process.env.BACKEND_URL || "http://backend:8000";
  const res = await fetch(`${backendUrl}/api/greet?name=${encodeURIComponent(name)}`, {
    cache: "no-store",
  });
  const data = await res.json(); // ← ブレークポイントを設定してステップ実行を確認
  return data.message as string;
}
