import java.awt.Color;
import java.awt.Dimension;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.geom.Rectangle2D;
import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.io.IOException;
import java.io.Writer;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.List;
import java.util.TimeZone;
import javax.imageio.ImageIO;

import org.apache.pdfbox.Loader;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDPageContentStream;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.rendering.ImageType;
import org.apache.pdfbox.rendering.PDFRenderer;
import org.apache.pdfbox.text.PDFTextStripper;
import org.apache.pdfbox.text.TextPosition;
import org.apache.poi.sl.usermodel.PictureData;
import org.apache.poi.sl.usermodel.Slide;
import org.apache.poi.sl.usermodel.SlideShow;
import org.apache.poi.sl.usermodel.SlideShowFactory;
import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.CellType;
import org.apache.poi.ss.usermodel.DataFormatter;
import org.apache.poi.ss.usermodel.DateUtil;
import org.apache.poi.ss.usermodel.FormulaEvaluator;
import org.apache.poi.ss.usermodel.Row;
import org.apache.poi.ss.usermodel.Sheet;
import org.apache.poi.ss.usermodel.Workbook;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import org.apache.poi.xslf.usermodel.XMLSlideShow;
import org.apache.poi.xslf.usermodel.XSLFPictureData;
import org.apache.poi.xslf.usermodel.XSLFPictureShape;
import org.apache.poi.xslf.usermodel.XSLFSlide;

import de.rototor.pdfbox.graphics2d.PdfBoxGraphics2D;

/**
 * Conversor Office do Toranja (roda sem interface, chamado pelo app).
 *
 *   slides-pdf   <entrada.pptx|ppt> <saida.pdf>
 *   slides-image <entrada.pptx|ppt> <pasta> <png|jpg>
 *   sheet-json   <entrada.xls|xlsx> <saida.json>
 *   pdf-pptx     <entrada.pdf> <saida.pptx>
 *   pdf-sheet    <entrada.pdf> <saida.json>
 */
public class ToranjaOffice {
    public static void main(String[] args) throws Exception {
        switch (args[0]) {
            case "slides-pdf": slidesToPdf(new File(args[1]), new File(args[2])); break;
            case "slides-image": slidesToImages(new File(args[1]), new File(args[2]), args[3]); break;
            case "sheet-json": sheetToJson(new File(args[1]), new File(args[2])); break;
            case "pdf-pptx": pdfToSlides(new File(args[1]), new File(args[2])); break;
            case "pdf-sheet": pdfToSheet(new File(args[1]), new File(args[2])); break;
            default: throw new IllegalArgumentException("comando desconhecido: " + args[0]);
        }
    }

    private static void quality(Graphics2D g) {
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setRenderingHint(RenderingHints.KEY_RENDERING, RenderingHints.VALUE_RENDER_QUALITY);
        g.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_BICUBIC);
        g.setRenderingHint(RenderingHints.KEY_FRACTIONALMETRICS, RenderingHints.VALUE_FRACTIONALMETRICS_ON);
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
    }

    // Cada slide é desenhado num Graphics2D que grava vetores direto no PDF.
    private static void slidesToPdf(File in, File out) throws Exception {
        try (SlideShow<?, ?> show = SlideShowFactory.create(in, null, true); PDDocument doc = new PDDocument()) {
            Dimension size = show.getPageSize();
            for (Slide<?, ?> slide : show.getSlides()) {
                PDPage page = new PDPage(new PDRectangle(size.width, size.height));
                doc.addPage(page);
                PdfBoxGraphics2D g = new PdfBoxGraphics2D(doc, size.width, size.height);
                quality(g);
                slide.draw(g);
                g.dispose();
                try (PDPageContentStream content = new PDPageContentStream(doc, page)) {
                    content.drawForm(g.getXFormObject());
                }
            }
            doc.save(out);
        }
    }

    private static void slidesToImages(File in, File dir, String format) throws Exception {
        dir.mkdirs();
        try (SlideShow<?, ?> show = SlideShowFactory.create(in, null, true)) {
            Dimension size = show.getPageSize();
            double scale = 1920.0 / size.width;
            int w = (int) Math.round(size.width * scale), h = (int) Math.round(size.height * scale);
            List<? extends Slide<?, ?>> slides = show.getSlides();
            int digits = String.valueOf(slides.size()).length();
            for (int i = 0; i < slides.size(); i++) {
                BufferedImage image = new BufferedImage(w, h, BufferedImage.TYPE_INT_RGB);
                Graphics2D g = image.createGraphics();
                quality(g);
                g.setPaint(Color.WHITE);
                g.fillRect(0, 0, w, h);
                g.scale(scale, scale);
                slides.get(i).draw(g);
                g.dispose();
                String name = String.format("%0" + digits + "d.%s", i + 1, format);
                ImageIO.write(image, format.equals("jpg") ? "jpeg" : "png", new File(dir, name));
            }
        }
    }

    // Cada página do PDF vira um slide com a página renderizada, centralizada.
    private static void pdfToSlides(File in, File out) throws Exception {
        try (PDDocument pdf = Loader.loadPDF(in); XMLSlideShow show = new XMLSlideShow()) {
            PDFRenderer renderer = new PDFRenderer(pdf);
            BufferedImage first = renderer.renderImageWithDPI(0, 72, ImageType.RGB);
            double slideW = 960, slideH = 960.0 * first.getHeight() / first.getWidth();
            show.setPageSize(new Dimension((int) slideW, (int) slideH));
            for (int i = 0; i < pdf.getNumberOfPages(); i++) {
                BufferedImage image = renderer.renderImageWithDPI(i, 200, ImageType.RGB);
                ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                ImageIO.write(image, "jpeg", bytes);
                XSLFPictureData data = show.addPicture(bytes.toByteArray(), PictureData.PictureType.JPEG);
                XSLFSlide slide = show.createSlide();
                XSLFPictureShape picture = slide.createPicture(data);
                double scale = Math.min(slideW / image.getWidth(), slideH / image.getHeight());
                double w = image.getWidth() * scale, h = image.getHeight() * scale;
                picture.setAnchor(new Rectangle2D.Double((slideW - w) / 2, (slideH - h) / 2, w, h));
            }
            try (FileOutputStream stream = new FileOutputStream(out)) { show.write(stream); }
        }
    }

    /** Uma linha de texto do PDF: palavras com início/fim horizontal e largura do espaço. */
    private static class Line {
        final List<String> words = new ArrayList<>();
        final List<float[]> spans = new ArrayList<>();

        /** Agrupa palavras próximas em células; espaços grandes separam células. Cada célula: {x0, x1} e texto. */
        List<Object[]> cells() {
            List<Object[]> cells = new ArrayList<>();
            for (int i = 0; i < words.size(); i++) {
                float[] span = spans.get(i);
                if (i == 0 || span[0] - spans.get(i - 1)[1] > spans.get(i - 1)[2] * 2.5f) {
                    cells.add(new Object[] { new float[] { span[0], span[1] }, words.get(i) });
                } else {
                    Object[] last = cells.get(cells.size() - 1);
                    ((float[]) last[0])[1] = span[1];
                    last[1] = last[1] + " " + words.get(i);
                }
            }
            return cells;
        }
    }

    /** Extrai tabelas do PDF, uma aba por página. */
    private static class TableStripper extends PDFTextStripper {
        final List<List<Line>> pages = new ArrayList<>();
        private Line line = new Line();

        TableStripper() throws IOException {
            setSortByPosition(true);
        }

        /** O PDFBox pode juntar células vizinhas numa "palavra"; separamos de novo pela posição de cada letra. */
        @Override
        protected void writeString(String text, List<TextPosition> positions) {
            StringBuilder word = new StringBuilder();
            float x0 = 0, x1 = 0, space = 1;
            TextPosition prev = null;
            for (TextPosition t : positions) {
                boolean blank = t.getUnicode().trim().isEmpty();
                boolean gap = prev != null && t.getXDirAdj() - (prev.getXDirAdj() + prev.getWidthDirAdj()) > Math.max(t.getWidthOfSpace(), 1f) * 0.6f;
                if ((blank || gap) && word.length() > 0) {
                    line.words.add(word.toString());
                    line.spans.add(new float[] { x0, x1, space });
                    word.setLength(0);
                }
                prev = t;
                if (blank) continue;
                if (word.length() == 0) x0 = t.getXDirAdj();
                word.append(t.getUnicode());
                x1 = t.getXDirAdj() + t.getWidthDirAdj();
                space = Math.max(t.getWidthOfSpace(), 1f);
            }
            if (word.length() > 0) {
                line.words.add(word.toString());
                line.spans.add(new float[] { x0, x1, space });
            }
        }

        @Override
        protected void writeLineSeparator() {
            flushLine();
        }

        @Override
        protected void writePageStart() {
            pages.add(new ArrayList<>());
        }

        @Override
        protected void writePageEnd() {
            flushLine();
        }

        private void flushLine() {
            if (!line.words.isEmpty() && !pages.isEmpty()) pages.get(pages.size() - 1).add(line);
            line = new Line();
        }
    }

    /**
     * Linhas com o número máximo de células definem as colunas: a borda de cada coluna é o início
     * mais à esquerda visto nessas linhas (o cabeçalho costuma começar na borda; números à direita não).
     * Linhas completas entram em ordem; nas demais, cada palavra vai para a última coluna que começa antes dela.
     */
    private static List<List<String>> layout(List<Line> lines) {
        int most = 1;
        for (Line l : lines) most = Math.max(most, l.cells().size());
        float[] left = new float[most];
        java.util.Arrays.fill(left, Float.MAX_VALUE);
        for (Line l : lines) {
            List<Object[]> cells = l.cells();
            if (cells.size() != most) continue;
            for (int c = 0; c < most; c++) left[c] = Math.min(left[c], ((float[]) cells.get(c)[0])[0]);
        }

        List<List<String>> rows = new ArrayList<>();
        for (Line l : lines) {
            String[] row = new String[most];
            List<Object[]> cells = l.cells();
            if (cells.size() == most) {
                for (int c = 0; c < most; c++) row[c] = (String) cells.get(c)[1];
            } else {
                for (int i = 0; i < l.words.size(); i++) {
                    float x = l.spans.get(i)[0];
                    int col = 0;
                    for (int c = 0; c < most; c++) if (left[c] <= x + l.spans.get(i)[2]) col = c;
                    row[col] = row[col] == null ? l.words.get(i) : row[col] + " " + l.words.get(i);
                }
            }
            List<String> out = new ArrayList<>();
            for (String cell : row) out.add(clean(cell == null ? "" : cell));
            rows.add(out);
        }
        return rows;
    }

    /** "79,6" (vírgula decimal) vira "79.6" para ser reconhecido como número. */
    private static String clean(String s) {
        String t = s.trim();
        return t.matches("-?\\d+,\\d+") ? t.replace(',', '.') : t;
    }

    private static void pdfToSheet(File in, File out) throws Exception {
        try (PDDocument pdf = Loader.loadPDF(in);
             Writer w = new OutputStreamWriter(new FileOutputStream(out), StandardCharsets.UTF_8)) {
            TableStripper stripper = new TableStripper();
            stripper.getText(pdf);
            w.write("[");
            for (int p = 0; p < stripper.pages.size(); p++) {
                if (p > 0) w.write(",");
                w.write("{\"name\":" + json("Página " + (p + 1)) + ",\"rows\":[");
                List<List<String>> rows = layout(stripper.pages.get(p));
                for (int r = 0; r < rows.size(); r++) {
                    if (r > 0) w.write(",");
                    w.write("[");
                    for (int c = 0; c < rows.get(r).size(); c++) {
                        if (c > 0) w.write(",");
                        w.write(json(rows.get(r).get(c)));
                    }
                    w.write("]");
                }
                w.write("]}");
            }
            w.write("]");
        }
    }

    // Planilha → JSON [{name, rows:[[...]]}], com números sem formatação de idioma e datas em ISO.
    private static void sheetToJson(File in, File out) throws Exception {
        SimpleDateFormat dateFormat = new SimpleDateFormat("yyyy-MM-dd");
        SimpleDateFormat dateTimeFormat = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss");
        dateFormat.setTimeZone(TimeZone.getTimeZone("UTC"));
        dateTimeFormat.setTimeZone(TimeZone.getTimeZone("UTC"));
        DataFormatter formatter = new DataFormatter();
        try (Workbook book = WorkbookFactory.create(in, null, true);
             Writer w = new OutputStreamWriter(new FileOutputStream(out), StandardCharsets.UTF_8)) {
            FormulaEvaluator evaluator = book.getCreationHelper().createFormulaEvaluator();
            w.write("[");
            for (int s = 0; s < book.getNumberOfSheets(); s++) {
                Sheet sheet = book.getSheetAt(s);
                if (s > 0) w.write(",");
                w.write("{\"name\":" + json(sheet.getSheetName()) + ",\"rows\":[");
                for (int r = 0; r <= sheet.getLastRowNum(); r++) {
                    if (r > 0) w.write(",");
                    w.write("[");
                    Row row = sheet.getRow(r);
                    int last = row == null ? 0 : Math.max(0, row.getLastCellNum());
                    for (int c = 0; c < last; c++) {
                        if (c > 0) w.write(",");
                        w.write(json(value(row.getCell(c), formatter, evaluator, dateFormat, dateTimeFormat)));
                    }
                    w.write("]");
                }
                w.write("]}");
            }
            w.write("]");
        }
    }

    private static String value(Cell cell, DataFormatter formatter, FormulaEvaluator evaluator,
                                SimpleDateFormat dateFormat, SimpleDateFormat dateTimeFormat) {
        if (cell == null) return "";
        CellType type = cell.getCellType();
        if (type == CellType.FORMULA) type = cell.getCachedFormulaResultType();
        try {
            switch (type) {
                case NUMERIC:
                    double d = cell.getNumericCellValue();
                    if (DateUtil.isCellDateFormatted(cell)) {
                        return (d % 1 == 0 ? dateFormat : dateTimeFormat).format(cell.getDateCellValue());
                    }
                    BigDecimal number = new BigDecimal(Double.toString(d)).stripTrailingZeros();
                    return number.abs().compareTo(new BigDecimal("1e15")) < 0 ? number.toPlainString() : number.toString();
                case STRING: return cell.getStringCellValue();
                case BOOLEAN: return cell.getBooleanCellValue() ? "TRUE" : "FALSE";
                case BLANK: return "";
                default: return formatter.formatCellValue(cell, evaluator);
            }
        } catch (Exception e) {
            return formatter.formatCellValue(cell);
        }
    }

    private static String json(String s) {
        StringBuilder b = new StringBuilder("\"");
        for (char ch : s.toCharArray()) {
            switch (ch) {
                case '"': b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\n': b.append("\\n"); break;
                case '\r': b.append("\\r"); break;
                case '\t': b.append("\\t"); break;
                default:
                    if (ch < 0x20) b.append(String.format("\\u%04x", (int) ch)); else b.append(ch);
            }
        }
        return b.append('"').toString();
    }
}
