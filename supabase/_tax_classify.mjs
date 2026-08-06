// ANÁLISIS (no setea nada): clasifica los 1557 canónicos en categoria/subcategoria
// usando nombre + descripcion_ia, mide cobertura y lista lo no clasificado.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const rows = (await c.query(`select codigo_barra, descripcion, coalesce(descripcion_ia,'') dia, coalesce(id_categoria,'') cat_actual
  from mos.productos where tipo_producto::text='CANONICO' and coalesce(estado,true) and descripcion_ia is not null`)).rows;

// Reglas: primer match gana. [regex sobre NOMBRE (+desc si empieza con ~), CATEGORIA, Subcategoría]
const R = [
  // ── LIMPIEZA
  [/LEJIA|CLOROX|SAPOLIO|AYUDIN|DETERGENTE|LAVAVAJILLA|JABON|SHAMPOO|SUAVIZANTE|DESINFECT|PINESOL|POETT|QUITAMANCHA|BLANQUEADOR|MATA ?RATA|RATICIDA|INSECTICIDA|SICARIO|ESCOBA|ESPONJA|PAÑO|GUANTE|TRAPEADOR/i, 'LIMPIEZA', null, (n)=> /MATA ?RATA|RATICIDA|INSECTICIDA|SICARIO/i.test(n) ? 'Plagas e insecticidas' : /LEJIA|CLOROX|BLANQUEADOR|PINESOL|POETT|DESINFECT/i.test(n) ? 'Lejías y desinfectantes' : /LAVAVAJILLA|AYUDIN|SAPOLIO/i.test(n) ? 'Lavavajillas' : /DETERGENTE|JABON|SHAMPOO|SUAVIZANTE|QUITAMANCHA/i.test(n) ? 'Detergentes y jabones' : 'Utensilios de limpieza'],
  // ── VINAGRES
  [/VINAGRE/i, 'VINAGRES', null, (n)=> /ARROZ/i.test(n) ? 'Vinagre de arroz' : /BALSAMIC/i.test(n) ? 'Balsámico' : /MANZANA/i.test(n) ? 'Vinagre de manzana' : 'Vinagre blanco y tinto'],
  // ── ACEITES
  [/ACEITE|OLIVA/i, 'ACEITES', null, (n)=> /OLIVA/i.test(n) ? 'Aceite de oliva' : /AJONJOLI|SESAMO|COCO|GIRASOL PREN/i.test(n) ? 'Aceites especiales' : 'Aceite vegetal'],
  // ── ENERGIZANTES / rehidratantes
  [/SPORADE|POWERADE|VOLT|ENERGIZANTE|RED BULL|360 ENERGY/i, 'ENERGIZANTES', null, ()=> 'Energizantes y rehidratantes'],
  // ── BEBIDAS
  [/GASEOSA|COCA ?COLA|INCA KOLA|SPRITE|FANTA|PEPSI|SODA .*ML|AGUA (MINERAL|SIN GAS|CON GAS|DE MESA)|CIELO|SAN MATEO|SAN LUIS/i, 'BEBIDAS', null, (n)=> /AGUA|CIELO|SAN MATEO|SAN LUIS/i.test(n) ? 'Aguas' : 'Gaseosas'],
  [/ZUKO|CIFRUT|REFRESCO|JUGO|NECTAR|PULP|FRUGOS|LIMONADA|CHICHA MORADA(?!.*GRANEL)/i, 'BEBIDAS', null, ()=> 'Jugos y refrescos'],
  [/CAFE|NESCAFE|ALTOMAYO|CAFETAL|KIRMA|ECCO\b|KROSS/i, 'BEBIDAS', null, (n)=> /ECCO|CEBADA INST/i.test(n) ? 'Cebada y sucedáneos' : 'Café'],
  [/COCOA|ACHOCOLATAD|MILO|ANGO\b|CHOCOLATE PARA TAZA|SOL DEL CUZCO|TAZA/i, 'BEBIDAS', null, ()=> 'Cocoa y chocolate de taza'],
  [/LECHE DE SOYA|BEBIDA VEGETAL|SOYA .*BEBIDA|MALTINA|BEBIDA/i, 'BEBIDAS', null, ()=> 'Otras bebidas'],
  // ── INFUSIONES
  [/FILTRANTE|MANZANILLA|ANIS .*FILTR|TE (VERDE|NEGRO|CANELA)|HIERBA LUISA|EMOLIENTE|BOLDO|INFUSION|MATE\b/i, 'INFUSIONES', null, (n)=> /EMOLIENTE/i.test(n) ? 'Emolientes' : 'Filtrantes e infusiones'],
  // ── LACTEOS
  [/LECHE (GLORIA|EVAPORADA|CONDENSADA|ENTERA|FRESCA|EN POLVO)|GLORIA .*LECHE|LECHE .*(TARRO|LATA|BOLSA|BOTELLA)|IDEAL\b|PURA VIDA|BONLE|LAIVE/i, 'LACTEOS', null, (n)=> /CONDENSADA/i.test(n) ? 'Leche condensada' : 'Leches'],
  [/MANTEQUILLA|MARGARINA|SELLO DE ORO|PRIMAVERA\b|CREMA DE LECHE|QUESO|YOGUR/i, 'LACTEOS', null, (n)=> /MANTEQUILLA|MARGARINA|SELLO DE ORO|PRIMAVERA/i.test(n) ? 'Mantequillas y margarinas' : /QUESO/i.test(n) ? 'Quesos' : 'Cremas y yogures'],
  // ── CONSERVAS
  [/ATUN|FILETE DE|GRATED|PORTOLA|FLORIDA .*(ATUN|FILETE)|CABALLA|SARDINA/i, 'CONSERVAS', null, ()=> 'Atún y pescados'],
  [/DURAZNO.*(LATA|CONSERVA|ALMIBAR)|COCTEL DE FRUTA|PIÑA .*LATA|ACONCAGUA/i, 'CONSERVAS', null, ()=> 'Frutas en almíbar'],
  [/CHAMPIÑON|ACEITUNA|ALCAPARRA|PIMIENTO.*(LATA|CONSERVA)|ESPARRAGO|TAUSI|MENSI\b/i, 'CONSERVAS', null, ()=> 'Verduras y encurtidos'],
  // ── MENESTRAS
  [/FRIJOL|FREJOL|PALLAR|GARBANZO|LENTEJA|ARVEJA|HABA(S)?\b|CARAOTA/i, 'MENESTRAS', null, (n)=> /FRIJOL|FREJOL|CARAOTA/i.test(n) ? 'Frijoles' : /LENTEJA/i.test(n) ? 'Lentejas' : /ARVEJA/i.test(n) ? 'Arvejas' : /GARBANZO/i.test(n) ? 'Garbanzos' : 'Pallares y habas'],
  [/MAIZ (MOTE|MOROCHO|CANCHA|CHULPI|PACCHO)|MOTE\b|MOROCHO|CANCHA|CHULPI|MAIZ MORADO|TRIGO (MOTE|RESBALADO|PELADO)|CEBADA (TOSTADA|GRANO)/i, 'MENESTRAS', null, ()=> 'Maíces y granos andinos'],
  // ── ENDULZANTES
  [/AZUCAR|CHANCACA|PANELA|STEVIA|EDULCORANTE|MIEL|ALGARROBINA|GLUCOSA|CARAMELO LIQUIDO/i, 'ENDULZANTES', null, (n)=> /MIEL|ALGARROBINA/i.test(n) ? 'Mieles y algarrobina' : /AZUCAR/i.test(n) ? 'Azúcares' : /CHANCACA|PANELA/i.test(n) ? 'Chancaca y panela' : /GLUCOSA|CARAMELO LIQ/i.test(n) ? 'Glucosa y jarabes' : 'Edulcorantes'],
  // ── PRODUCTOS_CHINOS / oriental
  [/SILLAO|SOYA .*(SALSA|1LT|500)|SIYAU|AJINOSILLAO|OSTION|OYSTER|SRIRACHA|TERIYAKI|HOISIN|WANTAN|SIU MAI|NORI|ALGA|DASHI|TOGARASHI|RAMEN|BAIXIANG|CHUBANG|HADAY|PEARL RIVER|KIKKO|MIRIN|SAKE|TAUSI|HONGO CHINO|SETA|SHIITAKE|CHAOKOH|BAMBU|WEI ?MAN|GUAN JI|ZHONGQIAO|WUFENG|XINGZHEN|YU XI|ZOBON|WHITE RABBIT|CHENG GONG|CHAN FU/i, 'PRODUCTOS_CHINOS', null, (n)=> /SILLAO|SOYA|SIYAU|AJINOSILLAO/i.test(n) ? 'Sillao y salsa de soya' : /OSTION|OYSTER|SRIRACHA|TERIYAKI|HOISIN|DASHI|TOGARASHI|MIRIN/i.test(n) ? 'Salsas y condimentos orientales' : /WANTAN|RAMEN|BAIXIANG|FIDEO/i.test(n) ? 'Fideos y sopas orientales' : /NORI|ALGA|HONGO|SETA|SHIITAKE|BAMBU/i.test(n) ? 'Setas y algas' : 'Otros orientales'],
  // ── SALSAS
  [/ALACENA|TARI\b|UCHUCUTA|HUANCAINA|OCOPA|MAYONESA|KETCHUP|MOSTAZA|SALSA (GOLF|TARTARA|BBQ|PICANTE|INGLESA|DE TOMATE|ROJA)|POMAROLA|TUCO|PASTA DE TOMATE|HUMO LIQUIDO|WORCESTER|TABASCO|AJI (MOLIDO|LICUADO)|ROCOTO (MOLIDO|LICUADO)|PASTA DE AJI|ADEREZO/i, 'SALSAS', null, (n)=> /MAYONESA|KETCHUP|MOSTAZA|GOLF|TARTARA/i.test(n) ? 'Cremas de mesa' : /TOMATE|POMAROLA|TUCO/i.test(n) ? 'Salsas de tomate' : /ALACENA|TARI|UCHUCUTA|HUANCAINA|OCOPA/i.test(n) ? 'Salsas peruanas listas' : /HUMO|INGLESA|WORCESTER|TABASCO/i.test(n) ? 'Sazonadores líquidos' : 'Pastas de ají y adobos'],
  // ── ESPECIAS
  [/AJINOMOTO|NAKAMITO|GLUTAMATO|UMAMI/i, 'ESPECIAS', null, ()=> 'Glutamato y umami'],
  [/SIBARITA|SAZONADOR|CUBITO|MAGGI|DOÑA GUSTA|BATIDOR CRIOLLO|SAZON LOPESA|LOPESA|COMPLETO\b/i, 'ESPECIAS', null, ()=> 'Sazonadores y cubitos'],
  [/PIMIENTA|CAYENA/i, 'ESPECIAS', null, ()=> 'Pimientas'],
  [/CANELA|CLAVO DE OLOR|CLAVO OLOR/i, 'ESPECIAS', null, ()=> 'Canela y clavo'],
  [/AJI (PANCA|MIRASOL|AMARILLO|COLORADO|LIMO)|PAPRIKA|PIMENTON|ACHIOTE|PALILLO|CURCUMA|AZAFRAN|COLOR\b/i, 'ESPECIAS', null, ()=> 'Ajíes y colorantes naturales'],
  [/COMINO|ANIS\b|AJONJOLI|HINOJO|LINAZA|MOSTAZA GRANO|CARDAMOMO|NUEZ MOSCADA|JENGIBRE|KION/i, 'ESPECIAS', null, ()=> 'Semillas y raíces aromáticas'],
  [/OREGANO|LAUREL|ROMERO|TOMILLO|ALBAHACA|HIERBA|PEREJIL|HUACATAY|CULANTRO/i, 'ESPECIAS', null, ()=> 'Hierbas secas'],
  [/^SAL\b|SAL (DE MESA|MARINA|YODADA|MARAS|ANDES|PARRILLA)|EMSAL|NORSAL|SALINAS/i, 'ESPECIAS', null, ()=> 'Sales'],
  [/AJO (ENTERO|POLVO|MOLIDO|GRANULADO)|CEBOLLA (POLVO|MOLIDA)|SIETE SABORES|MIX .*ESPECIA|ESPECIA/i, 'ESPECIAS', null, ()=> 'Ajo, cebolla y mezclas'],
  // ── GALLETAS_SNACKS
  [/GALLETA|SODA\b|VAINILLA .*PAQ|MOROCHAS|CASINO|PICARAS|RITZ|CLUB SOCIAL|OREO|CHOMP|GLACITAS|RELLENITA|MARGARITA|CREMA TROPICAL|CHAPLIN|TENTACION|WAFER|DIA\b.*GALLETA/i, 'GALLETAS_SNACKS', null, (n)=> /WAFER/i.test(n) ? 'Wafers' : /SODA|CLUB SOCIAL|RITZ|CREAM CRACKER|SALADA/i.test(n) ? 'Galletas saladas' : 'Galletas dulces'],
  [/PIQUEO|CHIFLE|SNACK|PAPA FRITA|CUATE|DE TODITO|TIYAPUY|MANI (SALADO|CONFITADO|TOSTADO)|HABAS (SALADA|TOSTADA)|CANCHITA|TORTEE|DORITOS|CHEESE TRIS|CHIZITO/i, 'GALLETAS_SNACKS', null, ()=> 'Snacks y piqueos'],
  // ── CONFITERIA
  [/CARAMELO|GOMITA|GOMA\b|CHUPETIN|CHICLE|TROMPADA|ALFAJOR|TOFEE|TOFFEE|MARSHMALLOW|MASMELO|ANGELITO|GRAGEA|LENTEJA CHOC|CHIN CHIN|CANDY|ALPENLIEBE|MENTITAS|HALLS|CEREZA CONFITADA|FRUTA CONFITADA|HIGO CONFITADO/i, 'CONFITERIA', null, (n)=> /CONFITADA|CONFITADO/i.test(n) ? 'Frutas confitadas' : /MARSHMALLOW|MASMELO/i.test(n) ? 'Marshmallows' : /CHICLE/i.test(n) ? 'Chicles' : 'Caramelos y golosinas'],
  [/CHOCOLATE|CHOCOTEJA|BOMBON|COBERTURA (BITTER|LECHE|BLANCA)|NEGUSA|TESORO|SUBLIME|TRIANGULO|PRINCESA|CAÑONAZO|VIZZIO|DONOFRIO.*CHOC/i, 'CONFITERIA', null, ()=> 'Chocolates y coberturas'],
  // ── GRANEL → frutos secos/deshidratados
  [/PASAS|GUINDON|CIRUELA SECA|DATIL|ARANDANO|BERRIES|HIGO SECO|DAMASCO|FRUTA DESHIDRATADA|COCO RALLADO|COCO EN/i, 'GRANEL', null, ()=> 'Frutas deshidratadas'],
  [/ALMENDRA|CASTAÑA|PECANA|NUEZ|MANI\b|MARAÑON|PISTACHO|AVELLANA|FRUTOS SECOS/i, 'GRANEL', null, ()=> 'Frutos secos'],
  [/CHIA|QUINUA|KIWICHA|CAÑIHUA|AMARANTO|AJONJOLI GRANEL|SEMILLA/i, 'GRANEL', null, ()=> 'Semillas y granos andinos'],
  [/HONGO|LAUREL GRANEL|CHARQUI|CAMARON SECO|PESCADO SECO|CECINA/i, 'GRANEL', null, ()=> 'Secos y deshidratados salados'],
  // ── ABARROTES
  [/ARROZ(?!.*GLUTINOSO)|COSTEÑO|VALLE NORTE|PAISANA.*ARROZ/i, 'ABARROTES', null, ()=> 'Arroz'],
  [/FIDEO|TALLARIN|SPAGHETTI|CABELLO DE ANGEL|LASAGNA|MACARRON|CANUTO|CODITO|ARITO|LETRITA|NICOLINI|DON VITTORIO|MOLITALIA.*FIDEO|TRIUNFO|PASTA\b/i, 'ABARROTES', null, ()=> 'Fideos y pastas'],
  [/HARINA|SEMOLA|MAIZENA|CHUÑO|ALMIDON|FECULA|PAN MOLIDO|PANKO|DEMSA|BLANCA FLOR.*HARINA|TOCOSH|MACA\b/i, 'ABARROTES', null, (n)=> /CHUÑO|ALMIDON|MAIZENA|FECULA/i.test(n) ? 'Almidones y chuño' : /PAN MOLIDO|PANKO/i.test(n) ? 'Apanaduras' : /MACA|TOCOSH/i.test(n) ? 'Harinas andinas' : 'Harinas'],
  [/AVENA|HOJUELA|CEREAL|GRANOLA|SALVADO|3 OSITOS|OSITOS|SANTA CATALINA/i, 'ABARROTES', null, ()=> 'Avenas y cereales'],
  [/SOPA (INSTANT|RAMEN)|AJINOMEN|SOPA SECA|CREMA DE (POLLO|GALLINA) SOBRE/i, 'ABARROTES', null, ()=> 'Sopas instantáneas'],
  [/HUEVO/i, 'ABARROTES', null, ()=> 'Huevos'],
  // ── INSUMOS_REPOSTERIA (comestibles)
  [/LEVADURA|POLVO DE HORNEAR|BICARBONATO|CREMOR|FLEISCHMAN|BAKELS/i, 'INSUMOS_REPOSTERIA', null, ()=> 'Levaduras y leudantes'],
  [/ESENCIA|COLORANTE|SABORIZANTE|VAINILLA (LIQ|NEGRITA)|AIRAMPO/i, 'INSUMOS_REPOSTERIA', null, ()=> 'Esencias y colorantes'],
  [/GELATINA|COLAPIZ|COLAPI|CMC\b|FLAN\b|MAZAMORRA|PUDIN/i, 'INSUMOS_REPOSTERIA', null, ()=> 'Gelatinas y postres en polvo'],
  [/MANJAR|FONDANT|CHANTILLY|CREMA PASTELERA|MASS CREAM|LECHE ASADA|TRES LECHES/i, 'INSUMOS_REPOSTERIA', null, ()=> 'Manjares y cremas'],
  [/CACAO|COCOA (WINTER|PURA)|ALGARROBO|CURAZAO/i, 'INSUMOS_REPOSTERIA', null, ()=> 'Cacao y derivados'],
  [/MANTECA|GORDITO|FAMOSA|CREMA VEGETAL/i, 'INSUMOS_REPOSTERIA', null, ()=> 'Mantecas'],
  [/OBLEA|PIONONO|HOJARASCA|TAPITA ALFAJOR|BUPAS|PREMEZCLA|BIZCOCHUELO|KEKE|TORTA .*PREMEZ/i, 'INSUMOS_REPOSTERIA', null, ()=> 'Premezclas y bases horneadas'],
  // ── DECORATIVOS
  [/GRAGEAS|PERLAS|CONFITE DECOR|VELA|VELITAS|ADORNO|FLORES? (DE AZUCAR|ARTIFICIAL)|MUÑEC|TOPPER|CINTA|LISTON|SILUETA|LETRERO|FELIZ CUMPLE/i, 'DECORATIVOS', null, (n)=> /VELA|VELITA/i.test(n) ? 'Velas de cumpleaños' : /CINTA|LISTON/i.test(n) ? 'Cintas y listones' : /GRAGEA|PERLA|CONFITE/i.test(n) ? 'Grageas y perlas comestibles' : 'Adornos y toppers'],
  // ── REPOSTERIA (herramientas)
  [/MOLDE|AROS? (DE|PARA)|BOQUILLA|MANGA (PASTELERA|REPOST)|CORTADOR|ESPATULA|BATIDOR|RODILLO|BASE GIRATORIA|TAPETE|SILICONA|COMFORMADOR|MARCADOR|PINCEL|BROCHA|RASPADOR|ALISADOR|SOPORTE|PORTA ?TORTA|CAKE TOOL|DUYA|CONO REPOST/i, 'REPOSTERIA', null, (n)=> /MOLDE|ARO/i.test(n) ? 'Moldes y aros' : /BOQUILLA|MANGA|DUYA/i.test(n) ? 'Boquillas y mangas' : /CORTADOR/i.test(n) ? 'Cortadores' : 'Herramientas de repostería'],
  // ── DESCARTABLES
  [/BOLSA|CELOFAN|POLIPROPILENO|ALUSA|ZIPLOC/i, 'DESCARTABLES', null, (n)=> /CELOFAN/i.test(n) ? 'Celofán y empaques' : 'Bolsas'],
  [/TAPER|ENVASE|POTE\b|BANDEJA|BASE (TECNOPOR|CARTON|ALUMINIO)|TECNOPOR|CONTENEDOR|CAJA (PARA TORTA|TORTA|PIZZA|CHIFA)|MICA\b|CUPCAKE.*(CAJA|ENVASE)|CLAMSHELL/i, 'DESCARTABLES', null, (n)=> /CAJA/i.test(n) ? 'Cajas para torta y delivery' : /BASE|TECNOPOR|BANDEJA/i.test(n) ? 'Bases y bandejas' : 'Envases y tapers'],
  [/VASO|PLATO|CUBIERTO|TENEDOR|CUCHARA|CUCHILLO DESC|SORBETE|CAÑITA|REMOVEDOR|CONTOMETRO|SERVILLETA|PAPEL (TOALLA|HIGIENICO|ALUMINIO|FILM|MANTECA|ARROZ|SEDA)|FILM|PIROTIN|BROQUETA|PALITO (BROCHETA|ANTICUCHO)|MONDADIENTE|PALILLO DIENTES|GORRO CHEF|GUANTE/i, 'DESCARTABLES', null, (n)=> /PAPEL|FILM|SERVILLETA/i.test(n) ? 'Papeles y films' : /PIROTIN/i.test(n) ? 'Pirotines' : /SORBETE|CAÑITA|REMOVEDOR/i.test(n) ? 'Sorbetes y removedores' : /BROQUETA|PALITO|MONDADIENTE/i.test(n) ? 'Palitos y brochetas' : 'Vasos, platos y cubiertos'],
  // ── VINOS_LICORES
  [/VINO|PISCO|RON\b|CERVEZA|SANGRIA|BORGOÑA|ANISADO|CREMA DE LICOR|LICOR/i, 'VINOS_LICORES', null, ()=> 'Vinos y licores'],
  // ══ v2: repesca de patrones vistos en "sin clasificar" ══
  [/AGUA GASIFICADA|^LOA |KRIS |PUNCH .*ML|GASIFICADA/i, 'BEBIDAS', null, (n)=> /AGUA/i.test(n) ? 'Aguas' : 'Jugos y refrescos'],
  [/CHOCOLATADA|MISKISIMO/i, 'BEBIDAS', null, ()=> 'Cocoa y chocolate de taza'],
  [/MUÑA|CEDRON|HORNIMAN|MC ?COLIN|ZURIT|HERBI\b/i, 'INFUSIONES', null, ()=> 'Filtrantes e infusiones'],
  [/SALSA DE SOYA|HOI ?SIN|SHIRACHA|LEE KUN KEE|KIKO SALSA|ARROZ GLUTINOSO|EXCEL RICE|PAPA SECA|CAMOTE SECO/i, 'PRODUCTOS_CHINOS', null, (n)=> /SOYA/i.test(n) ? 'Sillao y salsa de soya' : /HOI ?SIN|SHIRACHA/i.test(n) ? 'Salsas y condimentos orientales' : 'Otros orientales'],
  [/^BADIA |MOLINO VIEJO|AJO EN POLVO|CEBOLLA EN POLVO|AJINOMIX|PREPARADO (LECHON|POLLO)|MARINADO|ENELDO|ESTRAGON|GARAM|CURRY|PROVENCE|SALVIA|CLAVO ENTERO|SARTA/i, 'ESPECIAS', null, (n)=> /AJO |CEBOLLA /i.test(n) ? 'Ajo, cebolla y mezclas' : /PREPARADO|MARINADO|AJINOMIX/i.test(n) ? 'Sazonadores y cubitos' : /CLAVO/i.test(n) ? 'Canela y clavo' : 'Hierbas secas'],
  [/MAIZ (ASTILLA|PILPE|POP ?CORN)|POP ?CORN|ARVERJA|ARVEJA PARTIDA/i, 'MENESTRAS', null, (n)=> /ARV/i.test(n) ? 'Arvejas' : 'Maíces y granos andinos'],
  [/^BASE \d|BASE (RECTANGULAR|REDONDA|CUADRADA|DE (MEDIO|UN) KILO)|BASE \d+ BORDE/i, 'DESCARTABLES', null, ()=> 'Bases y bandejas'],
  [/^CAJA |TOPER|TOPPER ACRILICO|GALLETERA|VISOR/i, 'DESCARTABLES', null, (n)=> /CAJA/i.test(n) ? 'Cajas para torta y delivery' : 'Envases y tapers'],
  [/AEROGRAFO|PEGAMENTO REPOSTERO|CORTE DECORATIVO|ALAMBRE|PERLA (IMPORTADA|NACIONAL)|ISOMALT|GLASE|GLASEADO|AIRBRUSH/i, 'REPOSTERIA', null, (n)=> /PERLA|CORTE DECOR|ALAMBRE/i.test(n) ? 'Insumos de decoración' : 'Herramientas de repostería'],
  [/FUDGE|CUA CUA|BISCOCHO|BIZCOCHO|TRIDENT|CANCUN/i, 'CONFITERIA', null, (n)=> /TRIDENT/i.test(n) ? 'Chicles' : /FUDGE|CUA CUA/i.test(n) ? 'Chocolates y coberturas' : 'Caramelos y golosinas'],
  [/ALMIBAR/i, 'CONSERVAS', null, ()=> 'Frutas en almíbar'],
  [/C\.?M\.?C\.?$|COLAPIS/i, 'INSUMOS_REPOSTERIA', null, ()=> 'Gelatinas y postres en polvo'],
  [/LIMPIATODO|NORMITA/i, 'LIMPIEZA', null, ()=> 'Lejías y desinfectantes'],
  [/FOSFORO|ENCENDEDOR/i, 'OTROS', null, ()=> 'Fósforos y encendido'],
  [/PAPEL ORO|COMESTIBLE.*(DORADO|PLATEADO)|GUINDA/i, 'DECORATIVOS', null, (n)=> /GUINDA/i.test(n) ? 'Grageas y perlas comestibles' : 'Adornos y toppers'],
  [/MOLDADIENTE|MONDA ?DIENTE/i, 'DESCARTABLES', null, ()=> 'Palitos y brochetas'],
  [/CARTULINA|SCANNCUT|BRILLO|DISEÑO VARIADO|COLORES VARIADOS/i, 'DECORATIVOS', null, ()=> 'Adornos y toppers'],
  // nombres insuficientes ("X 12 UNID", "MEDIANO") → revisar a mano
  [/^(X \d+ ?UNI?D?|MEDIANO|PEQUEÑO|GRANDE|CHICO)\.?$/i, 'OTROS', null, ()=> 'Por revisar (nombre insuficiente)'],
];

const clasifica = (txt) => {
  for (const [re, cat, , subFn] of R) if (re.test(txt)) return { cat, sub: subFn(txt) };
  return null;
};
const out = {}, sinCat = [], asig = {};
for (const p of rows) {
  const n = p.descripcion;
  // 1ª pasada: nombre. 2ª pasada: descripción IA (solo 🧪📋✅, sin la línea 📦 que menciona envases y confunde)
  let hit = clasifica(n);
  if (!hit) {
    const diaUtil = p.dia.split('\n').filter(l => /^(🧪|📋|✅)/.test(l)).join(' ');
    hit = clasifica(diaUtil);
    if (hit) hit.via = 'dia';
  }
  if (!hit) { sinCat.push(n); continue; }
  asig[p.codigo_barra] = { cat: hit.cat, sub: hit.sub };
  out[hit.cat] = out[hit.cat] || {};
  out[hit.cat][hit.sub] = out[hit.cat][hit.sub] || { n: 0, ej: [] };
  out[hit.cat][hit.sub].n++;
  if (out[hit.cat][hit.sub].ej.length < 3) out[hit.cat][hit.sub].ej.push(n);
}
const clasif = rows.length - sinCat.length;
console.log(`clasificados: ${clasif}/${rows.length} (${(clasif / rows.length * 100).toFixed(1)}%) · sin clasificar: ${sinCat.length}`);
for (const cat of Object.keys(out).sort()) {
  const tot = Object.values(out[cat]).reduce((a, b) => a + b.n, 0);
  console.log(`\n${cat} (${tot})`);
  for (const [s, v] of Object.entries(out[cat]).sort((a, b) => b[1].n - a[1].n)) console.log(`   · ${s}: ${v.n}`);
}
fs.writeFileSync('_tax_arbol.json', JSON.stringify(out, null, 1));
fs.writeFileSync('_tax_asig.json', JSON.stringify(asig, null, 0));
console.log('\n── SIN CLASIFICAR (primeros 60):');
sinCat.slice(0, 60).forEach(x => console.log('   ? ' + x));
fs.writeFileSync('_tax_sincat.json', JSON.stringify(sinCat, null, 1));
await c.end();
