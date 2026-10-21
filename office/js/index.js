// Conversores do Toranja que rodam num WebKit invisível.
// Recebem bytes em base64 e devolvem JSON/HTML para o app.
import { renderAsync } from "docx-preview";
import { PagesDocument, NumbersDocument, KeynoteDocument } from "cupertino-files";

function bytesFromBase64(b64) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

const escape = (s) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

async function settle() {
  await document.fonts.ready;
  await Promise.all([...document.images].map((img) => img.complete ? null : new Promise((r) => { img.onload = img.onerror = r; })));
  // requestAnimationFrame não dispara num WebKit sem janela; um pequeno atraso basta para o layout.
  await new Promise((r) => setTimeout(r, 50));
}

/** Renderiza um .docx com paginação real e devolve o retângulo de cada página. */
async function renderDocx(b64) {
  const container = document.getElementById("doc");
  container.innerHTML = "";
  await renderAsync(bytesFromBase64(b64), container, container, {
    inWrapper: false,
    breakPages: true,
    ignoreLastRenderedPageBreak: false,
    useBase64URL: true,
    renderHeaders: true,
    renderFooters: true,
    renderFootnotes: true,
    renderEndnotes: true,
    experimental: true,
    // Fontes embutidas no .docx ficam "carregando" num WebKit invisível e o texto some; as do sistema bastam.
    ignoreFonts: true,
  });
  await settle();
  return [...container.querySelectorAll("section.docx")].map((s) => {
    const r = s.getBoundingClientRect();
    return [r.left + window.scrollX, r.top + window.scrollY, r.width, r.height];
  });
}

/** Texto de um intervalo com negrito/itálico, agrupando trechos de mesmo estilo. */
function styledHTML(doc, start, end, text) {
  let html = "";
  let runStart = 0;
  let current = null;
  const flush = (i) => {
    if (i <= runStart) return;
    let piece = escape(text.slice(runStart, i)).replace(/\u2028|\n/g, "<br>").replace(/\uFFFC/g, "");
    if (current?.italic) piece = `<em>${piece}</em>`;
    if (current?.bold) piece = `<strong>${piece}</strong>`;
    html += piece;
  };
  for (let i = 0; i < text.length; i++) {
    let f = {};
    try { f = doc.characterFormattingAt(start + i) ?? {}; } catch {}
    const key = { bold: !!f.bold, italic: !!f.italic };
    if (!current || key.bold !== current.bold || key.italic !== current.italic) {
      flush(i);
      runStart = i;
      current = key;
    }
  }
  flush(text.length);
  return html;
}

function tableHTML(table) {
  const rows = [];
  for (let r = 0; r < table.rowCount; r++) {
    const cells = [];
    for (let c = 0; c < table.columnCount; c++) cells.push(table.cellText(r, c) ?? "");
    rows.push(cells);
  }
  return rows;
}

/** Pages → HTML; Numbers → abas/linhas; Keynote → slides com título, corpo e notas. */
function readIWork(b64, app) {
  const bytes = bytesFromBase64(b64);
  if (app === "numbers") {
    const doc = NumbersDocument.load(bytes);
    const sheets = [];
    for (const sheet of doc.sheets()) {
      const tables = doc.tablesOnSheet(sheet.id);
      tables.forEach((table, i) => {
        const name = tables.length > 1 ? `${sheet.name ?? "Sheet"} - ${table.name ?? i + 1}` : (sheet.name ?? table.name ?? "Sheet");
        sheets.push({ name, rows: tableHTML(table) });
      });
    }
    return JSON.stringify({ app, sheets });
  }
  if (app === "keynote") {
    const doc = KeynoteDocument.load(bytes);
    const slides = doc.slides().filter((s) => !s.isSkipped).map((s) => {
      let texts = [];
      try { texts = s.textStorages().map((t) => t.text ?? "").filter(Boolean); } catch {}
      return { title: s.title ?? "", body: s.body ?? "", texts, notes: s.notes ?? "" };
    });
    return JSON.stringify({ app, slides });
  }
  const doc = PagesDocument.load(bytes);
  let html = "";
  let inList = false;
  for (const p of doc.paragraphs()) {
    const style = (p.styleName ?? "").toLowerCase();
    const text = p.text ?? "";
    if (!text.trim()) { if (inList) { html += "</ul>"; inList = false; } continue; }
    const body = styledHTML(doc, p.start, p.end, text);
    const bullet = /bullet|lista|list|marcador/.test(style);
    if (bullet && !inList) { html += "<ul>"; inList = true; }
    if (!bullet && inList) { html += "</ul>"; inList = false; }
    if (bullet) html += `<li>${body}</li>`;
    else if (/^title|^título/.test(style)) html += `<h1>${body}</h1>`;
    else if (/heading 1|título 1|cabeçalho 1|^heading$|^subtitle|^subtítulo/.test(style)) html += `<h2>${body}</h2>`;
    else if (/heading|título|cabeçalho/.test(style)) html += `<h3>${body}</h3>`;
    else html += `<p>${body}</p>`;
  }
  if (inList) html += "</ul>";
  // Tabelas dentro do documento vão no fim, como tabelas HTML.
  try {
    for (const table of doc.tables()) {
      html += "<table border=\"1\" cellpadding=\"4\" style=\"border-collapse:collapse\">";
      for (const row of tableHTML(table)) html += "<tr>" + row.map((c) => `<td>${escape(c)}</td>`).join("") + "</tr>";
      html += "</table>";
    }
  } catch {}
  return JSON.stringify({ app: "pages", html });
}

function base64FromBytes(bytes) {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

/** Cria um documento do Pages a partir de blocos [{kind: h1|h2|h3|p|li, runs: [{text, bold, italic}]}]. */
function makePages(json) {
  const blocks = JSON.parse(json);
  const doc = PagesDocument.blank();
  const styles = { h1: "Title", h2: "Heading", h3: "Heading 2", p: "Body", li: "Body" };
  for (const block of blocks) {
    const text = block.runs.map((r) => r.text).join("").replace(/\n/g, "\u2028");
    if (!text.trim()) continue;
    const index = doc.appendParagraph(text, styles[block.kind] ?? "Body", block.kind === "li" ? "Bullet" : undefined);
    let pos = doc.paragraphs()[index].start;
    for (const run of block.runs) {
      const length = run.text.length;
      // Títulos já são negrito pelo estilo; só parágrafos e listas recebem formatação direta.
      if (length && (run.bold || run.italic) && (block.kind === "p" || block.kind === "li")) {
        doc.applyCharacterFormatting(pos, pos + length, { bold: !!run.bold, italic: !!run.italic });
      }
      pos += length;
    }
  }
  return base64FromBytes(doc.save());
}

window.toranja = { renderDocx, readIWork, makePages };
