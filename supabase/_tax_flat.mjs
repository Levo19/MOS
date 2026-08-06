// Reglas DECLARATIVAS de taxonomía (primer match gana; dentro de una regla, el primer
// subpatrón que matchee decide la subcategoría; sub=null → default de la regla).
// Este mismo arreglo se exporta a mos.taxonomia_reglas (SQL 639) para clasificar
// productos FUTUROS en la BD — por eso: SIN lookaheads, \b se convierte a \y al emitir.
// Verificación: clasifica los 1557 canónicos y compara contra _tax_asig.json (el
// clasificador original ya aprobado) — deben coincidir 1 a 1.
import fs from 'fs';

// [patron, CATEGORIA, [ [subPatron, subcategoria], ..., [null, subDefault] ]]
export const REGLAS = [
  ['LEJIA|CLOROX|SAPOLIO|AYUDIN|DETERGENTE|LAVAVAJILLA|JABON|SHAMPOO|SUAVIZANTE|DESINFECT|PINESOL|POETT|QUITAMANCHA|BLANQUEADOR|MATA ?RATA|RATICIDA|INSECTICIDA|SICARIO|ESCOBA|ESPONJA|PAÑO|GUANTE|TRAPEADOR', 'LIMPIEZA', [
    ['MATA ?RATA|RATICIDA|INSECTICIDA|SICARIO', 'Plagas e insecticidas'],
    ['LEJIA|CLOROX|BLANQUEADOR|PINESOL|POETT|DESINFECT', 'Lejías y desinfectantes'],
    ['LAVAVAJILLA|AYUDIN|SAPOLIO', 'Lavavajillas'],
    ['DETERGENTE|JABON|SHAMPOO|SUAVIZANTE|QUITAMANCHA', 'Detergentes y jabones'],
    [null, 'Utensilios de limpieza']]],
  ['VINAGRE', 'VINAGRES', [
    ['ARROZ', 'Vinagre de arroz'], ['BALSAMIC', 'Balsámico'], ['MANZANA', 'Vinagre de manzana'],
    [null, 'Vinagre blanco y tinto']]],
  ['ACEITE|OLIVA', 'ACEITES', [
    ['OLIVA', 'Aceite de oliva'], ['AJONJOLI|SESAMO|COCO|GIRASOL PREN', 'Aceites especiales'],
    [null, 'Aceite vegetal']]],
  ['SPORADE|POWERADE|VOLT|ENERGIZANTE|RED BULL|360 ENERGY', 'ENERGIZANTES', [[null, 'Energizantes y rehidratantes']]],
  ['GASEOSA|COCA ?COLA|INCA KOLA|SPRITE|FANTA|PEPSI|SODA .*ML|AGUA (MINERAL|SIN GAS|CON GAS|DE MESA)|CIELO|SAN MATEO|SAN LUIS', 'BEBIDAS', [
    ['AGUA|CIELO|SAN MATEO|SAN LUIS', 'Aguas'], [null, 'Gaseosas']]],
  // (sin lookahead: CHICHA MORADA .* GRANEL cae antes, a maíces)
  ['CHICHA MORADA.*GRANEL', 'MENESTRAS', [[null, 'Maíces y granos andinos']]],
  ['ZUKO|CIFRUT|REFRESCO|JUGO|NECTAR|PULP|FRUGOS|LIMONADA|CHICHA MORADA', 'BEBIDAS', [[null, 'Jugos y refrescos']]],
  ['CAFE|NESCAFE|ALTOMAYO|CAFETAL|KIRMA|ECCO\\b|KROSS', 'BEBIDAS', [
    ['ECCO|CEBADA INST', 'Cebada y sucedáneos'], [null, 'Café']]],
  ['COCOA|ACHOCOLATAD|MILO|\\bANGO\\b|CHOCOLATE PARA TAZA|SOL DEL CUZCO|TAZA', 'BEBIDAS', [[null, 'Cocoa y chocolate de taza']]],
  ['LECHE DE SOYA|BEBIDA VEGETAL|SOYA .*BEBIDA|MALTINA|BEBIDA', 'BEBIDAS', [[null, 'Otras bebidas']]],
  ['FILTRANTE|MANZANILLA|ANIS .*FILTR|TE (VERDE|NEGRO|CANELA)|HIERBA LUISA|EMOLIENTE|BOLDO|INFUSION|MATE\\b', 'INFUSIONES', [
    ['EMOLIENTE', 'Emolientes'], [null, 'Filtrantes e infusiones']]],
  ['LECHE (GLORIA|EVAPORADA|CONDENSADA|ENTERA|FRESCA|EN POLVO)|GLORIA .*LECHE|LECHE .*(TARRO|LATA|BOLSA|BOTELLA)|IDEAL\\b|PURA VIDA|BONLE|LAIVE', 'LACTEOS', [
    ['CONDENSADA', 'Leche condensada'], [null, 'Leches']]],
  ['MANTEQUILLA|MARGARINA|SELLO DE ORO|PRIMAVERA\\b|CREMA DE LECHE|QUESO|YOGUR', 'LACTEOS', [
    ['MANTEQUILLA|MARGARINA|SELLO DE ORO|PRIMAVERA', 'Mantequillas y margarinas'],
    ['QUESO', 'Quesos'], [null, 'Cremas y yogures']]],
  ['ATUN|FILETE DE|GRATED|PORTOLA|FLORIDA .*(ATUN|FILETE)|CABALLA|SARDINA', 'CONSERVAS', [[null, 'Atún y pescados']]],
  ['DURAZNO.*(LATA|CONSERVA|ALMIBAR)|COCTEL DE FRUTA|PIÑA .*LATA|ACONCAGUA', 'CONSERVAS', [[null, 'Frutas en almíbar']]],
  ['CHAMPIÑON|ACEITUNA|ALCAPARRA|PIMIENTO.*(LATA|CONSERVA)|ESPARRAGO|TAUSI|MENSI\\b', 'CONSERVAS', [[null, 'Verduras y encurtidos']]],
  ['FRIJOL|FREJOL|PALLAR|GARBANZO|LENTEJA|ARVEJA|HABA(S)?\\b|CARAOTA', 'MENESTRAS', [
    ['FRIJOL|FREJOL|CARAOTA', 'Frijoles'], ['LENTEJA', 'Lentejas'], ['ARVEJA', 'Arvejas'],
    ['GARBANZO', 'Garbanzos'], [null, 'Pallares y habas']]],
  ['MAIZ (MOTE|MOROCHO|CANCHA|CHULPI|PACCHO)|MOTE\\b|MOROCHO|CANCHA|CHULPI|MAIZ MORADO|TRIGO (MOTE|RESBALADO|PELADO)|CEBADA (TOSTADA|GRANO)', 'MENESTRAS', [[null, 'Maíces y granos andinos']]],
  ['AZUCAR|CHANCACA|PANELA|STEVIA|EDULCORANTE|MIEL|ALGARROBINA|GLUCOSA|CARAMELO LIQUIDO', 'ENDULZANTES', [
    ['MIEL|ALGARROBINA', 'Mieles y algarrobina'], ['AZUCAR', 'Azúcares'],
    ['CHANCACA|PANELA', 'Chancaca y panela'], ['GLUCOSA|CARAMELO LIQ', 'Glucosa y jarabes'],
    [null, 'Edulcorantes']]],
  ['SILLAO|SOYA .*(SALSA|1LT|500)|SIYAU|AJINOSILLAO|OSTION|OYSTER|SRIRACHA|TERIYAKI|HOISIN|WANTAN|SIU MAI|NORI|ALGA|DASHI|TOGARASHI|RAMEN|BAIXIANG|CHUBANG|HADAY|PEARL RIVER|KIKKO|MIRIN|SAKE|TAUSI|HONGO CHINO|SETA|SHIITAKE|CHAOKOH|BAMBU|WEI ?MAN|GUAN JI|ZHONGQIAO|WUFENG|XINGZHEN|YU XI|ZOBON|WHITE RABBIT|CHENG GONG|CHAN FU', 'PRODUCTOS_CHINOS', [
    ['SILLAO|SOYA|SIYAU|AJINOSILLAO', 'Sillao y salsa de soya'],
    ['OSTION|OYSTER|SRIRACHA|TERIYAKI|HOISIN|DASHI|TOGARASHI|MIRIN', 'Salsas y condimentos orientales'],
    ['WANTAN|RAMEN|BAIXIANG|FIDEO', 'Fideos y sopas orientales'],
    ['NORI|ALGA|HONGO|SETA|SHIITAKE|BAMBU', 'Setas y algas'],
    [null, 'Otros orientales']]],
  ['ALACENA|TARI\\b|UCHUCUTA|HUANCAINA|OCOPA|MAYONESA|KETCHUP|MOSTAZA|SALSA (GOLF|TARTARA|BBQ|PICANTE|INGLESA|DE TOMATE|ROJA)|POMAROLA|TUCO|PASTA DE TOMATE|HUMO LIQUIDO|WORCESTER|TABASCO|AJI (MOLIDO|LICUADO)|ROCOTO (MOLIDO|LICUADO)|PASTA DE AJI|ADEREZO', 'SALSAS', [
    ['MAYONESA|KETCHUP|MOSTAZA|GOLF|TARTARA', 'Cremas de mesa'],
    ['TOMATE|POMAROLA|TUCO', 'Salsas de tomate'],
    ['ALACENA|TARI|UCHUCUTA|HUANCAINA|OCOPA', 'Salsas peruanas listas'],
    ['HUMO|INGLESA|WORCESTER|TABASCO', 'Sazonadores líquidos'],
    [null, 'Pastas de ají y adobos']]],
  ['AJINOMOTO|NAKAMITO|GLUTAMATO|UMAMI', 'ESPECIAS', [[null, 'Glutamato y umami']]],
  ['SIBARITA|SAZONADOR|CUBITO|MAGGI|DOÑA GUSTA|BATIDOR CRIOLLO|SAZON LOPESA|LOPESA|COMPLETO\\b', 'ESPECIAS', [[null, 'Sazonadores y cubitos']]],
  ['PIMIENTA|CAYENA', 'ESPECIAS', [[null, 'Pimientas']]],
  ['CANELA|CLAVO DE OLOR|CLAVO OLOR', 'ESPECIAS', [[null, 'Canela y clavo']]],
  ['AJI (PANCA|MIRASOL|AMARILLO|COLORADO|LIMO)|PAPRIKA|PIMENTON|ACHIOTE|PALILLO|CURCUMA|AZAFRAN|COLOR\\b', 'ESPECIAS', [[null, 'Ajíes y colorantes naturales']]],
  ['COMINO|ANIS\\b|AJONJOLI|HINOJO|LINAZA|MOSTAZA GRANO|CARDAMOMO|NUEZ MOSCADA|JENGIBRE|KION', 'ESPECIAS', [[null, 'Semillas y raíces aromáticas']]],
  ['OREGANO|LAUREL|ROMERO|TOMILLO|ALBAHACA|HIERBA|PEREJIL|HUACATAY|CULANTRO', 'ESPECIAS', [[null, 'Hierbas secas']]],
  ['^SAL\\b|SAL (DE MESA|MARINA|YODADA|MARAS|ANDES|PARRILLA)|EMSAL|NORSAL|SALINAS', 'ESPECIAS', [[null, 'Sales']]],
  ['AJO (ENTERO|POLVO|MOLIDO|GRANULADO)|CEBOLLA (POLVO|MOLIDA)|SIETE SABORES|MIX .*ESPECIA|ESPECIA', 'ESPECIAS', [[null, 'Ajo, cebolla y mezclas']]],
  ['GALLETA|SODA\\b|VAINILLA .*PAQ|MOROCHAS|CASINO|PICARAS|RITZ|CLUB SOCIAL|OREO|CHOMP|GLACITAS|RELLENITA|MARGARITA|CREMA TROPICAL|CHAPLIN|TENTACION|WAFER|DIA\\b.*GALLETA', 'GALLETAS_SNACKS', [
    ['WAFER', 'Wafers'], ['SODA|CLUB SOCIAL|RITZ|CREAM CRACKER|SALADA', 'Galletas saladas'],
    [null, 'Galletas dulces']]],
  ['PIQUEO|CHIFLE|SNACK|PAPA FRITA|CUATE|DE TODITO|TIYAPUY|MANI (SALADO|CONFITADO|TOSTADO)|HABAS (SALADA|TOSTADA)|CANCHITA|TORTEE|DORITOS|CHEESE TRIS|CHIZITO', 'GALLETAS_SNACKS', [[null, 'Snacks y piqueos']]],
  ['CARAMELO|GOMITA|GOMA\\b|CHUPETIN|CHICLE|TROMPADA|ALFAJOR|TOFEE|TOFFEE|MARSHMALLOW|MASMELO|ANGELITO|GRAGEA|LENTEJA CHOC|CHIN CHIN|CANDY|ALPENLIEBE|MENTITAS|HALLS|CEREZA CONFITADA|FRUTA CONFITADA|HIGO CONFITADO', 'CONFITERIA', [
    ['CONFITADA|CONFITADO', 'Frutas confitadas'], ['MARSHMALLOW|MASMELO', 'Marshmallows'],
    ['CHICLE', 'Chicles'], [null, 'Caramelos y golosinas']]],
  ['CHOCOLATE|CHOCOTEJA|BOMBON|COBERTURA (BITTER|LECHE|BLANCA)|NEGUSA|TESORO|SUBLIME|TRIANGULO|PRINCESA|CAÑONAZO|VIZZIO|DONOFRIO.*CHOC', 'CONFITERIA', [[null, 'Chocolates y coberturas']]],
  ['PASAS|GUINDON|CIRUELA SECA|DATIL|ARANDANO|BERRIES|HIGO SECO|DAMASCO|FRUTA DESHIDRATADA|COCO RALLADO|COCO EN', 'GRANEL', [[null, 'Frutas deshidratadas']]],
  ['ALMENDRA|CASTAÑA|PECANA|NUEZ|MANI\\b|MARAÑON|PISTACHO|AVELLANA|FRUTOS SECOS', 'GRANEL', [[null, 'Frutos secos']]],
  ['CHIA|QUINUA|KIWICHA|CAÑIHUA|AMARANTO|AJONJOLI GRANEL|SEMILLA', 'GRANEL', [[null, 'Semillas y granos andinos']]],
  ['HONGO|LAUREL GRANEL|CHARQUI|CAMARON SECO|PESCADO SECO|CECINA', 'GRANEL', [[null, 'Secos y deshidratados salados']]],
  // (sin lookahead: ARROZ GLUTINOSO/EXCEL RICE es oriental y cae antes que "ARROZ")
  ['ARROZ GLUTINOSO|EXCEL RICE', 'PRODUCTOS_CHINOS', [[null, 'Otros orientales']]],
  ['ARROZ|COSTEÑO|VALLE NORTE|PAISANA.*ARROZ', 'ABARROTES', [[null, 'Arroz']]],
  ['FIDEO|TALLARIN|SPAGHETTI|CABELLO DE ANGEL|LASAGNA|MACARRON|CANUTO|CODITO|ARITO|LETRITA|NICOLINI|DON VITTORIO|MOLITALIA.*FIDEO|TRIUNFO|PASTA\\b', 'ABARROTES', [[null, 'Fideos y pastas']]],
  ['HARINA|SEMOLA|MAIZENA|CHUÑO|ALMIDON|FECULA|PAN MOLIDO|PANKO|DEMSA|BLANCA FLOR.*HARINA|TOCOSH|MACA\\b', 'ABARROTES', [
    ['CHUÑO|ALMIDON|MAIZENA|FECULA', 'Almidones y chuño'], ['PAN MOLIDO|PANKO', 'Apanaduras'],
    ['MACA|TOCOSH', 'Harinas andinas'], [null, 'Harinas']]],
  ['AVENA|HOJUELA|CEREAL|GRANOLA|SALVADO|3 OSITOS|OSITOS|SANTA CATALINA', 'ABARROTES', [[null, 'Avenas y cereales']]],
  ['SOPA (INSTANT|RAMEN)|AJINOMEN|SOPA SECA|CREMA DE (POLLO|GALLINA) SOBRE', 'ABARROTES', [[null, 'Sopas instantáneas']]],
  ['HUEVO', 'ABARROTES', [[null, 'Huevos']]],
  ['LEVADURA|POLVO DE HORNEAR|BICARBONATO|CREMOR|FLEISCHMAN|BAKELS', 'INSUMOS_REPOSTERIA', [[null, 'Levaduras y leudantes']]],
  ['ESENCIA|COLORANTE|SABORIZANTE|VAINILLA (LIQ|NEGRITA)|AIRAMPO', 'INSUMOS_REPOSTERIA', [[null, 'Esencias y colorantes']]],
  ['GELATINA|COLAPIZ|COLAPI|CMC\\b|FLAN\\b|MAZAMORRA|PUDIN', 'INSUMOS_REPOSTERIA', [[null, 'Gelatinas y postres en polvo']]],
  ['MANJAR|FONDANT|CHANTILLY|CREMA PASTELERA|MASS CREAM|LECHE ASADA|TRES LECHES', 'INSUMOS_REPOSTERIA', [[null, 'Manjares y cremas']]],
  ['CACAO|COCOA (WINTER|PURA)|ALGARROBO|CURAZAO', 'INSUMOS_REPOSTERIA', [[null, 'Cacao y derivados']]],
  ['MANTECA|GORDITO|FAMOSA|CREMA VEGETAL', 'INSUMOS_REPOSTERIA', [[null, 'Mantecas']]],
  ['OBLEA|PIONONO|HOJARASCA|TAPITA ALFAJOR|BUPAS|PREMEZCLA|BIZCOCHUELO|KEKE|TORTA .*PREMEZ', 'INSUMOS_REPOSTERIA', [[null, 'Premezclas y bases horneadas']]],
  ['GRAGEAS|PERLAS|CONFITE DECOR|VELA|VELITAS|ADORNO|FLORES? (DE AZUCAR|ARTIFICIAL)|MUÑEC|TOPPER|CINTA|LISTON|SILUETA|LETRERO|FELIZ CUMPLE', 'DECORATIVOS', [
    ['VELA|VELITA', 'Velas de cumpleaños'], ['CINTA|LISTON', 'Cintas y listones'],
    ['GRAGEA|PERLA|CONFITE', 'Grageas y perlas comestibles'], [null, 'Adornos y toppers']]],
  ['MOLDE|AROS? (DE|PARA)|BOQUILLA|MANGA (PASTELERA|REPOST)|CORTADOR|ESPATULA|BATIDOR|RODILLO|BASE GIRATORIA|TAPETE|SILICONA|COMFORMADOR|MARCADOR|PINCEL|BROCHA|RASPADOR|ALISADOR|SOPORTE|PORTA ?TORTA|CAKE TOOL|DUYA|CONO REPOST', 'REPOSTERIA', [
    ['MOLDE|ARO', 'Moldes y aros'], ['BOQUILLA|MANGA|DUYA', 'Boquillas y mangas'],
    ['CORTADOR', 'Cortadores'], [null, 'Herramientas de repostería']]],
  ['BOLSA|CELOFAN|POLIPROPILENO|ALUSA|ZIPLOC', 'DESCARTABLES', [
    ['CELOFAN', 'Celofán y empaques'], [null, 'Bolsas']]],
  ['TAPER|ENVASE|POTE\\b|BANDEJA|BASE (TECNOPOR|CARTON|ALUMINIO)|TECNOPOR|CONTENEDOR|CAJA (PARA TORTA|TORTA|PIZZA|CHIFA)|MICA\\b|CUPCAKE.*(CAJA|ENVASE)|CLAMSHELL', 'DESCARTABLES', [
    ['CAJA', 'Cajas para torta y delivery'], ['BASE|TECNOPOR|BANDEJA', 'Bases y bandejas'],
    [null, 'Envases y tapers']]],
  ['VASO|PLATO|CUBIERTO|TENEDOR|CUCHARA|CUCHILLO DESC|SORBETE|CAÑITA|REMOVEDOR|CONTOMETRO|SERVILLETA|PAPEL (TOALLA|HIGIENICO|ALUMINIO|FILM|MANTECA|ARROZ|SEDA)|FILM|PIROTIN|BROQUETA|PALITO (BROCHETA|ANTICUCHO)|MONDADIENTE|PALILLO DIENTES|GORRO CHEF|GUANTE', 'DESCARTABLES', [
    ['PAPEL|FILM|SERVILLETA', 'Papeles y films'], ['PIROTIN', 'Pirotines'],
    ['SORBETE|CAÑITA|REMOVEDOR', 'Sorbetes y removedores'],
    ['BROQUETA|PALITO|MONDADIENTE', 'Palitos y brochetas'],
    [null, 'Vasos, platos y cubiertos']]],
  ['VINO|PISCO|RON\\b|CERVEZA|SANGRIA|BORGOÑA|ANISADO|CREMA DE LICOR|LICOR', 'VINOS_LICORES', [[null, 'Vinos y licores']]],
  // ── repesca (v2) ──
  ['AGUA GASIFICADA|^LOA |KRIS |PUNCH .*ML|GASIFICADA', 'BEBIDAS', [
    ['AGUA', 'Aguas'], [null, 'Jugos y refrescos']]],
  ['CHOCOLATADA|MISKISIMO', 'BEBIDAS', [[null, 'Cocoa y chocolate de taza']]],
  ['MUÑA|CEDRON|HORNIMAN|MC ?COLIN|ZURIT|HERBI\\b', 'INFUSIONES', [[null, 'Filtrantes e infusiones']]],
  ['SALSA DE SOYA|HOI ?SIN|SHIRACHA|LEE KUN KEE|KIKO SALSA|ARROZ GLUTINOSO|EXCEL RICE|PAPA SECA|CAMOTE SECO', 'PRODUCTOS_CHINOS', [
    ['SOYA', 'Sillao y salsa de soya'], ['HOI ?SIN|SHIRACHA', 'Salsas y condimentos orientales'],
    [null, 'Otros orientales']]],
  ['^BADIA |MOLINO VIEJO|AJO EN POLVO|CEBOLLA EN POLVO|AJINOMIX|PREPARADO (LECHON|POLLO)|MARINADO|ENELDO|ESTRAGON|GARAM|CURRY|PROVENCE|SALVIA|CLAVO ENTERO|SARTA', 'ESPECIAS', [
    ['AJO |CEBOLLA ', 'Ajo, cebolla y mezclas'], ['PREPARADO|MARINADO|AJINOMIX', 'Sazonadores y cubitos'],
    ['CLAVO', 'Canela y clavo'], [null, 'Hierbas secas']]],
  ['MAIZ (ASTILLA|PILPE|POP ?CORN)|POP ?CORN|ARVERJA|ARVEJA PARTIDA', 'MENESTRAS', [
    ['ARV', 'Arvejas'], [null, 'Maíces y granos andinos']]],
  ['^BASE \\d|BASE (RECTANGULAR|REDONDA|CUADRADA|DE (MEDIO|UN) KILO)|BASE \\d+ BORDE', 'DESCARTABLES', [[null, 'Bases y bandejas']]],
  ['^CAJA |TOPER|TOPPER ACRILICO|GALLETERA|VISOR', 'DESCARTABLES', [
    ['CAJA', 'Cajas para torta y delivery'], [null, 'Envases y tapers']]],
  ['AEROGRAFO|PEGAMENTO REPOSTERO|CORTE DECORATIVO|ALAMBRE|PERLA (IMPORTADA|NACIONAL)|ISOMALT|GLASE|GLASEADO|AIRBRUSH', 'REPOSTERIA', [
    ['PERLA|CORTE DECOR|ALAMBRE', 'Insumos de decoración'], [null, 'Herramientas de repostería']]],
  ['FUDGE|CUA CUA|BISCOCHO|BIZCOCHO|TRIDENT|CANCUN', 'CONFITERIA', [
    ['TRIDENT', 'Chicles'], ['FUDGE|CUA CUA', 'Chocolates y coberturas'],
    [null, 'Caramelos y golosinas']]],
  ['ALMIBAR', 'CONSERVAS', [[null, 'Frutas en almíbar']]],
  ['C\\.?M\\.?C\\.?$|COLAPIS', 'INSUMOS_REPOSTERIA', [[null, 'Gelatinas y postres en polvo']]],
  ['LIMPIATODO|NORMITA', 'LIMPIEZA', [[null, 'Lejías y desinfectantes']]],
  ['FOSFORO|ENCENDEDOR', 'OTROS', [[null, 'Fósforos y encendido']]],
  ['PAPEL ORO|COMESTIBLE.*(DORADO|PLATEADO)|GUINDA', 'DECORATIVOS', [
    ['GUINDA', 'Grageas y perlas comestibles'], [null, 'Adornos y toppers']]],
  ['MOLDADIENTE|MONDA ?DIENTE', 'DESCARTABLES', [[null, 'Palitos y brochetas']]],
  ['CARTULINA|SCANNCUT|BRILLO|DISEÑO VARIADO|COLORES VARIADOS', 'DECORATIVOS', [[null, 'Adornos y toppers']]],
  ['^(X \\d+ ?UNI?D?|MEDIANO|PEQUEÑO|GRANDE|CHICO)\\.?$', 'OTROS', [[null, 'Por revisar (nombre insuficiente)']]],
];

export function clasificar(nombre, dia) {
  const probar = (txt) => {
    if (!txt) return null;
    for (const [pat, cat, subs] of REGLAS) {
      if (!new RegExp(pat, 'i').test(txt)) continue;
      for (const [sp, sub] of subs) if (sp === null || new RegExp(sp, 'i').test(txt)) return { cat, sub };
    }
    return null;
  };
  let hit = probar(nombre);
  if (!hit && dia) {
    const util = dia.split('\n').filter(l => /^(🧪|📋|✅)/.test(l)).join(' ');
    hit = probar(util);
  }
  return hit;
}

// ── verificación contra el clasificador original aprobado ──
if (process.argv[1] && process.argv[1].endsWith('_tax_flat.mjs')) {
  const pkg = await import('pg');
  const c = new pkg.default.Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
  await c.connect();
  const rows = (await c.query(`select codigo_barra, descripcion, coalesce(descripcion_ia,'') dia
    from mos.productos where tipo_producto::text='CANONICO' and coalesce(estado,true) and descripcion_ia is not null`)).rows;
  await c.end();
  const asig = JSON.parse(fs.readFileSync('_tax_asig.json', 'utf8'));
  let ok = 0, sin = 0; const difs = [];
  for (const p of rows) {
    const h = clasificar(p.descripcion, p.dia);
    const o = asig[p.codigo_barra];
    if (!h) { sin++; difs.push(['SIN', p.descripcion, o ? o.cat + '/' + o.sub : '—']); continue; }
    if (o && (o.cat !== h.cat || o.sub !== h.sub)) difs.push(['DIF', p.descripcion, `${o.cat}/${o.sub} → ${h.cat}/${h.sub}`]);
    else ok++;
  }
  console.log(`iguales: ${ok}/${rows.length} · sin clasificar: ${sin} · difs: ${difs.length}`);
  difs.slice(0, 40).forEach(d => console.log('  ', d[0], '·', d[1], '·', d[2]));
}
