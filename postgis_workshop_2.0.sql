--------------------------------------------
-- Advanced Spatial Analysis with PostGIS
-- Pierre Racine
-- Version 2.0, August 2017
--------------------------------------------
-- Start the PostgreSQL server
-- Start PgAdmin III
-- Connect to the PostgreSQL server
-- Create a new database ("FOSS4G2017")
-- Install PostGIS in the new database and check version
CREATE EXTENSION postgis;
SELECT postgis_full_version();

--------------------------------------------
-- Load the forest cover shapefile
--------------------------------------------
-- Determine the SRID of the shapefile with http://prj2epsg.org/search
-- You can also search for keywords from the .prj file in the spatial_ref_sys table:
SELECT * 
FROM spatial_ref_sys 
WHERE srtext LIKE '%MTM%' AND srtext LIKE '%NAD83%';

-- Load the shapefile
-- shp2pgsql -s 32187 -W LATIN1 -I "D:\Formations\PostGIS\04 - FOSS4G 2017\Attendees\data\forestcover\forestcover.shp" "a_forestcover_mtm7" | psql -U "postgres" -d "FOSS4G2017"
-- -W for attributes with accents
-- -I to create a spatial index

 -- Display in OpenJump or QGIS
SELECT * 
FROM a_forestcover_mtm7;

-------------------------------------------------------------------------------------------------------------------
-- Load the PostGIS Addons (for ST_GeoTableSummary() and others later) and run the test file.
-------------------------------------------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- 1.1) Create a summary of the topological properties of the forest cover
--------------------------------------------------------------------------------

--DROP TABLE IF EXISTS a_forestcover_mtm7_summary;
CREATE TABLE a_forestcover_mtm7_summary AS
SELECT * 
FROM ST_GeoTableSummary('public', 'a_forestcover_mtm7', 'geom', 'gid', 10, 'all');

-- Display the summary
SELECT * 
FROM a_forestcover_mtm7_summary;

-- Display the invalid geometry in OpenJump or QGIS
SELECT * FROM a_forestcover_mtm7 WHERE NOT ST_IsValid(geom) AND ST_GeometryType(geom) = 'ST_MultiPolygon';

-----------------------------------
-- 1.2) Fix the invalid geometry
-----------------------------------
UPDATE a_forestcover_mtm7 
SET geom = ST_MakeValid(geom) 
WHERE NOT ST_IsValid(geom) AND ST_GeometryType(geom) = 'ST_MultiPolygon';

-- Regenerate the summary (should take longer now that it can analyze the overlaps) and display it
DROP TABLE IF EXISTS a_forestcover_mtm7_summary;
CREATE TABLE a_forestcover_mtm7_summary AS
SELECT * FROM ST_GeoTableSummary('public', 'a_forestcover_mtm7', 'geom', 'gid', 10, 'all');

SELECT * FROM a_forestcover_mtm7_summary;

-- Display the overlaps in OpenJump or QGIS
SELECT * FROM a_forestcover_mtm7_summary
WHERE summary = '3';

-- Alternative way to check for overlaps. 
-- Compare the sum of the individual areas with the area of the merged polygons. 24s
SELECT 'sum of areas'::text, sum(ST_Area(geom)) area FROM a_forestcover_mtm7
UNION ALL
SELECT 'area of union'::text, ST_Area(ST_Union(geom)) area FROM a_forestcover_mtm7;

-- Sum the overlapping areas - 2132m
SELECT sum(countsandareas) FROM a_forestcover_mtm7_summary
WHERE summary = '3';

------------------------------------------------------------------------------------------------------------------------
-- 2.1) Fix (remove) Overlapping Geometry Parts. 
--      EXTERIOR RINGS METHOD by deconstructing/reconstructing the polygons.
--      https://trac.osgeo.org/postgis/wiki/UsersWikiExamplesOverlayTables
--
--      Slow: About one hour for about 6000 polygons.
--      Memory overflow when too many polygons.
--      Remove every holes from multipolygons as well (if that's what you want).
--      No index required.
--      Link to original attribute have to be constructed spatially.
------------------------------------------------------------------------------------------------------------------------

-- 1) Extract all the polygons exterior rings and make them simple polygons (holes are lost)
--DROP TABLE IF EXISTS b_forest_no_overlaps_mtm7_ring_method_rings;
CREATE TABLE b_forest_no_overlaps_mtm7_ring_method_rings AS
SELECT gid id, 
       ctype, 
       height, 
       ST_MakePolygon(ST_ExteriorRing((ST_Dump(geom)).geom)) geom
FROM a_forestcover_mtm7;

-- 2) Index them so we can join back with them later to reassign the attributes to the final (fixed) coverage
CREATE INDEX ON b_forest_no_overlaps_mtm7_ring_method_rings USING gist (geom);

-- Create a new table with (almost) no overlaps. 37 minutes
--DROP TABLE If EXISTS b_forest_no_overlaps_mtm7_ring_method_final;
CREATE TABLE b_forest_no_overlaps_mtm7_ring_method_final AS
WITH extrings_union AS ( -- 3) Union all the polygons exterior rings together into a single geometry
  SELECT ST_Union(ST_ExteriorRing(geom)) geom
  FROM b_forest_no_overlaps_mtm7_ring_method_rings
), polygons AS ( -- 4) Reconstruct individual polygons from these rings (multi-polygons are broken into many polygons. We will re-union them later.)
  SELECT (ST_Dump((SELECT ST_Polygonize(geom) geom FROM extrings_union))).geom geom
), polygons_with_ids AS ( -- 5) Join each unique polygon back with the original polygon to get the right attributes (sorted by id DESC)
  SELECT DISTINCT ON (p.geom) p.geom, r.id, r.ctype, r.height
  FROM  polygons p LEFT JOIN b_forest_no_overlaps_mtm7_ring_method_rings r ON (ST_Within(ST_PointOnSurface(p.geom), r.geom))
  ORDER BY p.geom, id DESC
) -- 6) Re-union polygons sharing the same id together
SELECT id, ctype, height, ST_Union(geom) geom
FROM polygons_with_ids
GROUP BY id, ctype;

-- Summarize the resulting table
--DROP TABLE IF EXISTS b_forest_no_overlaps_mtm7_ring_method_summary;
CREATE TABLE b_forest_no_overlaps_mtm7_ring_method_summary AS
SELECT * FROM ST_GeoTableSummary('public', 'b_forest_no_overlaps_mtm7_ring_method_final', 'geom', 'id', 10, 'all');

SELECT * FROM b_forest_no_overlaps_mtm7_ring_method_summary;

-- Gaps are unioned together. Delete them... we will fill them later.
DELETE FROM public.b_forest_no_overlaps_mtm7_ring_method_final 
WHERE id IS NULL;

-- Check the sum of areas.
SELECT 'sum of areas'::text, sum(ST_Area(geom)) area FROM b_forest_no_overlaps_mtm7_ring_method_final
UNION ALL
SELECT 'area of union'::text, ST_Area(ST_Union(geom)) area FROM b_forest_no_overlaps_mtm7_ring_method_final;

------------------------------------------------------------------------------------------------------------------------
-- 2.2) Fix (remove) Overlapping Geometry Parts. 
--      DIFFERENCE AGGREGATE METHOD by clipping overlapping polygons and merging overlapping parts with the polygon 
--      having the biggest area.
--
--      Imperfect: leave some very small overlaps.
--      Very fast: 24 seconds for 7500 polygons. Index on geometry necessary.
--      Depends on the PostGIS Addons.
------------------------------------------------------------------------------------------------------------------------

-- Create a new table with (almost) no overlaps. 24s
--DROP TABLE IF EXISTS b_forest_no_overlaps_mtm7_diff_method;
CREATE TABLE b_forest_no_overlaps_mtm7_diff_method AS 
SELECT a.gid, a.ctype, a.height, ST_DifferenceAgg(a.geom, b.geom) geom -- Remove, in this polygon, all the overlapping parts from other polygons
FROM a_forestcover_mtm7 a, 
     a_forestcover_mtm7 b
WHERE a.gid = b.gid OR -- Make sure the polygon is compared to itself (and the clipped by ST_DifferenceAgg())
      ((ST_Contains(a.geom, b.geom) OR -- Select all the containing, contained and overlapping polygons
        ST_Contains(b.geom, a.geom) OR 
        ST_Overlaps(a.geom, b.geom)) AND 
       (ST_Area(a.geom) < ST_Area(b.geom) OR -- Make sure only the smallest ones are removed from the biggest ones
        (ST_Area(a.geom) = ST_Area(b.geom) AND -- If areas are equal, arbitrarily remove one from the other but in a determined order so its not done twice.
         ST_AsText(a.geom) < ST_AsText(b.geom))))
GROUP BY a.gid, a.ctype
HAVING ST_Area(ST_DifferenceAgg(a.geom, b.geom)) > 0 AND NOT ST_IsEmpty(ST_DifferenceAgg(a.geom, b.geom)); -- Don't keep the very small and empty

-- Display in OpenJump or QGIS
SELECT * 
FROM b_forest_no_overlaps_mtm7_diff_method;

-- Check areas again. 20s
SELECT 'sum of areas'::text, sum(ST_Area(geom)) area FROM b_forest_no_overlaps_mtm7_diff_method
UNION ALL
SELECT 'area of union'::text, ST_Area(ST_Union(geom)) area FROM b_forest_no_overlaps_mtm7_diff_method;

-- Resummarize the table now running only the OVL summary
--DROP TABLE IF EXISTS b_forest_no_overlaps_mtm7_summary;
CREATE TABLE b_forest_no_overlaps_mtm7_diff_method_summary AS
SELECT * FROM ST_GeoTableSummary('public', 'b_forest_no_overlaps_mtm7_diff_method', 'geom', 'gid', 10, 'ovl');

SELECT * FROM b_forest_no_overlaps_mtm7_diff_method_summary;

-- Sum the overlapping areas - 7.84806046765884e-008m
SELECT sum(countsandareas) FROM b_forest_no_overlaps_mtm7_diff_method_summary
WHERE summary = '3';

----------------------------------------------------------------------------------------------
-- 2.3) Fix (remove) Overlapping Geometry Parts. 
--      SPLIT AGGREGATE METHOD by spliting overlapping polygons and removing duplicates.
--      Imperfect: leave some very small overlaps.
--      Fast: 60 seconds for 7500 polygons. Index on geometry necessary.
--      Depends on the PostGIS Addons.
----------------------------------------------------------------------------------------------
--DROP TABLE IF EXISTS b_forest_no_overlaps_mtm7_split_method;
CREATE TABLE b_forest_no_overlaps_mtm7_split_method AS
SELECT DISTINCT ON (geom) 
       a.gid,
       a.ctype, 
       a.height, 
       unnest(ST_SplitAgg(a.geom, b.geom, 0.00001)) geom -- Select only one geometry from an identical set. Remove the DISTINCT if you want to keep them.
FROM a_forestcover_mtm7 a,
     a_forestcover_mtm7 b
WHERE ST_Equals(a.geom, b.geom) OR
      ST_Contains(a.geom, b.geom) OR
      ST_Contains(b.geom, a.geom) OR
      ST_Overlaps(a.geom, b.geom)
GROUP BY a.gid
ORDER BY geom, max(ST_Area(a.geom)) DESC;

-- Summarize the resulting table
--DROP TABLE IF EXISTS b_forest_no_overlaps_mtm7_split_method_summary;
CREATE TABLE b_forest_no_overlaps_mtm7_split_method_summary AS
SELECT * FROM ST_GeoTableSummary('public', 'b_forest_no_overlaps_mtm7_split_method', 'geom', 'gid', 10, 'all');

SELECT * FROM b_forest_no_overlaps_mtm7_split_method_summary;

-- Display in OpenJump or QGIS
SELECT * 
FROM b_forest_no_overlaps_mtm7_split_method;

-- Check areas again. 20s
SELECT 'sum of areas'::text, sum(ST_Area(geom)) area FROM b_forest_no_overlaps_mtm7_split_method
UNION ALL
SELECT 'area of union'::text, ST_Area(ST_Union(geom)) area FROM b_forest_no_overlaps_mtm7_split_method;

-- Sum the overlapping areas - 1.20575769339967e-008
SELECT sum(countsandareas) FROM b_forest_no_overlaps_mtm7_split_method_summary
WHERE summary = '3';

-----------------------------------------------------------------------
-- 2.4) Parallelize the overlap removal method (2.3)
-----------------------------------------------------------------------

-- Add a column with the area BEFORE splitting the coverage so we can merge overlaping part with the polygon having the biggest area BEFORE splitting
ALTER TABLE a_forestcover_mtm7 ADD COLUMN area double precision;
UPDATE a_forestcover_mtm7 SET area = ST_Area(geom);

-- Split the forest cover into tiles. 12s
--DROP TABLE IF EXISTS d_forestcover_mtm7_splitted_1000;
CREATE TABLE d_forestcover_mtm7_splitted_1000 AS
SELECT gid, ctype, height, area, (sp).*
FROM (SELECT gid, area, height, ctype, ST_SplitByGrid(geom, 1000) sp
      FROM a_forestcover_mtm7) foo;

-- gid is not unique anymore. Add a unique ad
SELECT ST_AddUniqueID('public', 'd_forestcover_mtm7_splitted_1000', 'id');

-- Index the geomtries
CREATE INDEX ON d_forestcover_mtm7_splitted_1000 USING gist (geom);

-- Summarize the table
--DROP TABLE IF EXISTS d_forestcover_mtm7_splitted_1000_summary;
CREATE TABLE d_forestcover_mtm7_splitted_1000_summary AS
SELECT * FROM ST_geoTableSummary('public', 'd_forestcover_mtm7_splitted_1000', 'geom', 'id', null, 'all');

SELECT * FROM d_forestcover_mtm7_splitted_1000_summary;

-- Fix ST_GeometryCollection
UPDATE d_forestcover_mtm7_splitted_1000 SET geom = ST_CollectionExtract(geom, 3)
WHERE ST_GeometryType(geom) = 'ST_GeometryCollection';

-- Determine the grid index horizontal range. 248 - 268
SELECT min(x) xmin, max(x) xmax
FROM d_forestcover_mtm7_splitted_1000;

-- Remove overlaps group of tile by group of tiles on different processors (each query takes less than 10s)
CREATE TABLE d_forestcover_mtm7_splitted_1000_no_overlaps_248_253 AS
--CREATE TABLE d_forestcover_mtm7_splitted_1000_no_overlaps_253_258 AS
--CREATE TABLE d_forestcover_mtm7_splitted_1000_no_overlaps_258_263 AS
--CREATE TABLE d_forestcover_mtm7_splitted_1000_no_overlaps_263_268 AS
WITH tiles AS (
  SELECT * 
  FROM d_forestcover_mtm7_splitted_1000
WHERE x >= 248 AND x < 253
--WHERE x >= 253 AND x < 258
--WHERE x >= 258 AND x < 263
--WHERE x >= 263 AND x < 268
)
SELECT a.id, a.gid, a.ctype, a.height, ST_DifferenceAgg(a.geom, b.geom) geom
FROM tiles a,
     tiles b
WHERE a.tid = b.tid AND -- Consider polygons from the same tile only
      (a.id = b.id OR
      ((ST_Overlaps(a.geom, b.geom) OR
       ST_Contains(a.geom, b.geom) OR
       ST_Contains(b.geom, a.geom)) AND
       (a.area < b.area OR 
        (a.area = b.area AND a.id < b.id))))
GROUP BY a.id, a.gid, a.ctype, a.height
HAVING ST_Area(ST_DifferenceAgg(a.geom, b.geom)) > 0 AND NOT ST_IsEmpty(ST_DifferenceAgg(a.geom, b.geom));

-- Merge all the tables together
CREATE TABLE d_forestcover_mtm7_splitted_1000_no_overlaps AS
SELECT gid, ctype, height, ST_Union(geom) geom
FROM (SELECT * FROM d_forestcover_mtm7_splitted_1000_no_overlaps_248_253
      UNION ALL
      SELECT * FROM d_forestcover_mtm7_splitted_1000_no_overlaps_253_258
      UNION ALL
      SELECT * FROM d_forestcover_mtm7_splitted_1000_no_overlaps_258_263
      UNION ALL
      SELECT * FROM d_forestcover_mtm7_splitted_1000_no_overlaps_263_268
     ) foo
GROUP BY gid, ctype, height;

-- Summarize the table
--DROP TABLE IF EXISTS d_forestcover_mtm7_splitted_1000_nooverlaps_summary;
CREATE TABLE d_forestcover_mtm7_splitted_1000_nooverlaps_summary AS
SELECT * FROM ST_geoTableSummary('public', 'd_forestcover_mtm7_splitted_1000_no_overlaps', 'geom', 'gid', null, 'all');

SELECT * FROM d_forestcover_mtm7_splitted_1000_nooverlaps_summary;

------------------------------------------------------
-- 3) Gap filling.
------------------------------------------------------

-- Identify gaps, 21 sec.
--DROP TABLE IF EXISTS e_forest_gaps_mtm7;
CREATE TABLE e_forest_gaps_mtm7 AS
SELECT geom, ST_Area(geom) area
-- Create an extent a bit larger than the full extent of the coverage and remove the union of all geometries from it
FROM (SELECT (ST_Dump(ST_Difference(ST_Buffer(ST_SetSRID(ST_Extent(geom)::geometry, min(ST_SRID(geom))), 0.01), ST_Union(geom)))).*
      FROM b_forest_no_overlaps_mtm7_diff_method) foo
WHERE path[1] != 1 -- Do not select the external big polygon
ORDER BY area DESC;

-- Display in OpenJump or QGIS
SELECT * 
FROM e_forest_gaps_mtm7;

-- Remove gaps. 23 secs.
--DROP TABLE IF EXISTS e_forest_no_gaps_mtm7;
CREATE TABLE e_forest_no_gaps_mtm7 AS
WITH gaps AS (
 SELECT geom
 -- 1) Create an extent a bit larger than the full extent of the coverage and remove the union of all geometries from it
 FROM (SELECT (ST_Dump(ST_Difference(ST_Buffer(ST_SetSRID(ST_Extent(geom)::geometry, min(ST_SRID(geom))), 0.01), ST_Union(geom)))).*
       FROM b_forest_no_overlaps_mtm7_diff_method) foo
 WHERE path[1] != 1 AND ST_Area(geom) > 0.000001 -- Do not select the external big polygon
), assignations AS ( -- 2) Find the biggest geometry touching every gaps
 SELECT DISTINCT ON (gaps.geom) ov.gid ovid, gaps.geom
 FROM b_forest_no_overlaps_mtm7_diff_method ov, gaps
 WHERE ST_Intersects(ov.geom, gaps.geom)
 ORDER BY gaps.geom, ST_Area(ov.geom) DESC
) -- 3) Union every original geometry with its possibly associated gap
SELECT ov.gid, ov.ctype, ov.height, ST_Union(CASE WHEN ass.geom IS NULL THEN ov.geom ELSE ST_Union(ov.geom, ass.geom) END) geom
FROM b_forest_no_overlaps_mtm7_diff_method ov LEFT OUTER JOIN assignations ass ON (ov.gid = ass.ovid)
GROUP BY ov.gid, ov.ctype, ov.height;

-- Compare sum of areas with exterior ring of union
--DROP TABLE IF EXISTS u_forest_union_without_gaps;
CREATE TABLE e_forest_union_no_gaps AS
SELECT ST_Union(geom) geom FROM e_forest_no_gaps_mtm7;

--DROP TABLE IF EXISTS u_forest_union_with_gaps;
CREATE TABLE e_forest_union_with_gaps AS
SELECT ST_Union(geom) geom FROM b_forest_no_overlaps_mtm7_diff_method;

-- We expect 1) to be smaller than the others and 2) to be equal et 3) and 4)
SELECT '1) sum of areas before gap removal', sum(ST_Area(geom)) FROM b_forest_no_overlaps_mtm7_diff_method
UNION ALL
SELECT '2) sum of areas after gap removal', sum(ST_Area(geom)) FROM e_forest_no_gaps_mtm7
UNION ALL
SELECT '3) area of union (ext ring) without gaps', ST_Area(ST_NBiggestExteriorRings(geom, 1)) FROM e_union_no_gaps
UNION ALL
SELECT '4) area of union (ext ring) with gaps', ST_Area(ST_NBiggestExteriorRings(geom, 1)) FROM e_union_with_gaps;

-- Display in OpenJump or QGIS
SELECT * 
FROM e_forest_no_gaps_mtm7;

-- Summarize the table
--DROP TABLE IF EXISTS e_forest_no_gaps_mtm7_summary;
CREATE TABLE e_forest_no_gaps_mtm7_summary AS
SELECT * FROM ST_geoTableSummary('public', 'e_forest_no_gaps_mtm7', 'geom', 'gid', null, 'all');

SELECT * FROM e_forest_no_gaps_mtm7_summary;

-- Identify gaps in the new table, 21 sec.
--DROP TABLE IF EXISTS e_forest_gaps_mtm7_2;
CREATE TABLE e_forest_gaps_mtm7_2 AS
SELECT geom, ST_Area(geom) area
-- Create an extent a bit larger than the full extent of the coverage and remove the union of all geometries from it
FROM (SELECT (ST_Dump(ST_Difference(ST_Buffer(ST_SetSRID(ST_Extent(geom)::geometry, min(ST_SRID(geom))), 0.01), ST_Union(geom)))).*
      FROM e_forest_no_gaps_mtm7) foo
WHERE path[1] != 1 -- Do not select the external big polygon
ORDER BY area DESC;

-- Display in OpenJump or QGIS
SELECT * 
FROM e_forest_gaps_mtm7_2;


-----------------------------------------------------------------------
-- 4.1 Extraction from POLYGONS for POINTS
-----------------------------------------------------------------------
-- Load the Montmorency Forest limits (to create random points inside)
-- shp2pgsql -s 4269:32187 -W LATIN1 -I "D:\Formations\PostGIS\04 - FOSS4G 2017\Attendees\data\limits_FM\limits_FM.shp" "a_limits_fm_mtm7" | psql -U "postgres" -d "FOSS4G2017"
-- -s reproject from WGS 84 to MTM 7

-- Check in the geometry_column view that b_limits_fm_mtm7 is in 32187

-- Display in OpenJump or QGIS
SELECT * 
FROM a_limits_fm_mtm7;

-----------------------------------------------------------------------
-- 4.1.1) Extraction from POLYGONS for POINTS (with possible duplicates)
-----------------------------------------------------------------------
-- Generate random points in the limits_fm
--DROP TABLE IF EXISTS f_random_points_fm_1000_mtm7;
CREATE TABLE f_random_points_fm_1000_mtm7 AS
SELECT ST_RandomPoints(ST_Union(geom), 1000, 0) geom 
FROM a_limits_fm_mtm7;

-- Add a spatial index on the points
CREATE INDEX f_random_points_fm_1000_mtm7_geom_gist 
ON f_random_points_fm_1000_mtm7 USING gist (geom);

-- Add a unique identifier to each point
SELECT ST_AddUniqueID('f_random_points_fm_1000_mtm7', 'id', true);

-- Display in OpenJump or QGIS
SELECT * 
FROM f_random_points_fm_1000_mtm7;

-- Extract a cover type value for each POINT
--DROP TABLE IF EXISTS f_random_points_fm_1000_cover_mtm7;
CREATE TABLE f_random_points_fm_1000_cover_mtm7 AS
SELECT p.id, 
       f.ctype ctype, 
       f.height, 
       p.geom geom
FROM f_random_points_fm_1000_mtm7 p, 
     e_forest_no_gaps_mtm7 f
WHERE ST_Intersects(p.geom, f.geom);

-- Make sure there are no duplicates (one point could intersect with two polygons at the same time)
SELECT ST_ColumnIsUnique('f_random_points_fm_1000_cover_mtm7', 'id');

-----------------------------------------------------------------------------------------------------------
-- 4.1.2) Extraction from POLYGONS for POINTS (with no duplicates)
-----------------------------------------------------------------------------------------------------------
-- If by any bad chance (you really have to be unlucky!), one point intersects with two or more polygons 
-- at the same time you can choose between the many duplicates with a DISTINCT clause...

-- Make one point fall eactly on the vextex of two polygons
UPDATE f_random_points_fm_1000_mtm7 SET geom = ST_SetSRID(ST_MakePoint(255032, 5236276), 32187) WHERE id = 540;

-- Re-extract the cover type value for each POINT
--DROP TABLE IF EXISTS f_random_points_fm_1000_cover_mtm7_2;
CREATE TABLE f_random_points_fm_1000_cover_mtm7_2 AS
SELECT p.id, 
       f.ctype ctype, 
       f.height, 
       p.geom geom
FROM f_random_points_fm_1000_mtm7 p, e_forest_no_gaps_mtm7 f
WHERE ST_Intersects(p.geom, f.geom);

-- Make sure there are no duplicates (one point could intersect with two polygons at the same time)
SELECT ST_ColumnIsUnique('f_random_points_fm_1000_cover_mtm7_2', 'id');

-- Display them
SELECT id, count(*) cnt
FROM f_random_points_fm_1000_cover_mtm7_2
GROUP BY id
HAVING count(*) > 1;

-- Display them in OpenJump or QGIS
SELECT * 
FROM f_random_points_fm_1000_cover_mtm7_2
WHERE id = 540;

-- So a better extraction query to avoid duplicates in the first place would have been:
--DROP TABLE IF EXISTS f_random_points_fm_1000_cover_mtm7_3;
CREATE TABLE f_random_points_fm_1000_cover_mtm7_3 AS
SELECT DISTINCT ON (p.id) p.id, 
                          f.ctype ctype, 
                          f.height, 
                          p.geom geom
FROM f_random_points_fm_1000_mtm7 p, 
     e_forest_no_gaps_mtm7 f
WHERE ST_Intersects(p.geom, f.geom)
ORDER BY p.id, height DESC;

SELECT ST_ColumnIsUnique('f_random_points_fm_1000_cover_mtm7_3', 'id');

SELECT * 
FROM f_random_points_fm_1000_cover_mtm7_3
WHERE id = 540;

-- Another option is to aggregate the numeric values from all duplicates. 
-- We can take the min, the max or the average for the numeric values and 
-- the max or min for the literal values.
--DROP TABLE IF EXISTS f_random_points_fm_1000_cover_mtm7_4;
CREATE TABLE f_random_points_fm_1000_cover_mtm7_4 AS
SELECT p.id, 
       min(f.ctype) ctype, 
       avg(f.height), 
       p.geom geom
FROM f_random_points_fm_1000_mtm7 p, e_forest_no_gaps_mtm7 f
WHERE ST_Intersects(p.geom, f.geom)
GROUP BY p.id, p.geom;

SELECT ST_ColumnIsUnique('f_random_points_fm_1000_cover_mtm7_4', 'id');

SELECT * 
FROM f_random_points_fm_1000_cover_mtm7_4
WHERE id = 540;

-----------------------------------------------------
-- 4.2) Extraction from POLYGONS for POLYGONS 
-----------------------------------------------------
-- Create a 100m buffer table and index it. 30000 m square
--DROP TABLE IF EXISTS g_random_buffers_fm_1000_mtm7;
CREATE TABLE g_random_buffers_fm_1000_mtm7 AS
SELECT id, ST_Buffer(geom, 100) geom
FROM f_random_points_fm_1000_mtm7;

-- Create the a spatial index on the buffers
CREATE INDEX g_random_buffers_fm_1000_mtm7_geom_gist ON g_random_buffers_fm_1000_mtm7 USING gist (geom);

-- Display in OpenJump or QGIS
SELECT * 
FROM g_random_buffers_fm_1000_mtm7;

-----------------------------------------------------------------------
-- 4.2.1) Extraction nominal values from POLYGONS for POLYGONS
-----------------------------------------------------------------------
-- Extract the area covered and the proportion of each type of forest cover for each buffer. 11s
--DROP TABLE IF EXISTS g_random_buffers_fm_coverarea_1000_mtm7;
CREATE TABLE g_random_buffers_fm_coverarea_1000_mtm7 AS
WITH buffer_parts AS (
  SELECT buf.id, ctype, ST_Area(buf.geom) bufferarea, ST_Intersection(buf.geom, c.geom) geom
  FROM g_random_buffers_fm_1000_mtm7 buf, a_forestcover_mtm7 c
  WHERE ST_Intersects(buf.geom, c.geom)
)
SELECT id, 
       ctype, 
       sum(ST_Area(geom)) area, 
       round(sum(ST_Area(geom))/min(bufferarea) * 1000) / 10 prop, -- tricky part
       ST_Union(geom) geom
FROM buffer_parts foo
GROUP BY id, ctype
ORDER BY id, area DESC, ctype;

-- Display
SELECT * 
FROM g_random_buffers_fm_coverarea_1000_mtm7;

--------------------------------------------------------------------------------
-- 4.2.2) Extraction of quantitative summaries from POLYGONS for POLYGONS
--------------------------------------------------------------------------------
-- Extract the area weigted forest cover height for each buffer using ST_AreaWeightedSummaryStats(). 5s
--DROP TABLE IF EXISTS g_random_buffers_fm_wmheight_1000_mtm7;
CREATE TABLE g_random_buffers_fm_wmheight_1000_mtm7 AS
WITH polygon_parts_and_areas AS (
  SELECT buf.id, 
         height, 
         ST_Intersection(fc.geom, buf.geom) geom
  FROM a_forestcover_mtm7 fc, g_random_buffers_fm_1000_mtm7 buf
  WHERE ST_Intersects(fc.geom, buf.geom)
), area_weighted_summaries AS (
  SELECT id, 
         ST_AreaWeightedSummaryStats(geom, height) aws
  FROM polygon_parts_and_areas
  GROUP BY id
)
SELECT id,
       (aws).geom, 
       (aws).weightedmean weighted_mean_height
FROM area_weighted_summaries;

-- Display
SELECT * 
FROM g_random_buffers_fm_wmheight_1000_mtm7;

--------------------------------------------
-- 5) Extraction from RASTER
--------------------------------------------
-- Load elevation raster files covering the Montmorency Forest in-db. 4m
-- Pixel size is 60m x 100m.
-- Elevation rasters are SRTM tiles downloaded from http://srtm.csi.cgiar.org/SELECTION/inputCoord.asp

-- raster2pgsql -t 10x10 -I -C -x -Y "D:\Formations\PostGIS\04 - FOSS4G 2017\Attendees\data\srtm\tif\srtm_22_03.tif" a_elevation_fm_10x10_wgs84 | psql -U postgres -d "FOSS4G2017"

-- raster2pgsql -t 20x20 -I -C -x -Y "D:\Formations\PostGIS\04 - FOSS4G 2017\Attendees\data\srtm\tif\srtm_22_03.tif" a_elevation_fm_20x20_wgs84 | psql -U postgres -d "FOSS4G2017"

-- raster2pgsql -t 100x100 -I -C -x -Y "D:\Formations\PostGIS\04 - FOSS4G 2017\Attendees\data\srtm\tif\srtm_22_03.tif" a_elevation_fm_100x100_wgs84 | psql -U postgres -d "FOSS4G2017"

-- -t split the raster into small tiles
-- -I create a spatial index on the tiles
-- -C add all the constraint necessary to display metadata in the raster_columns table
-- -x prevent adding the max extent constraint (which is long to add) so we can append raster to the table afterward
-- -Y make loading MUCH faster by using copy statements instead of insert statements

-- Display the 10x10 tiles in OpenJump or QGIS
SELECT rid, rast::geometry
FROM a_elevation_fm_10x10_wgs84;

-- Display the Montmorency Forest limits in OpenJump or QGIS
SELECT ST_Transform(geom, 4326) geom
FROM a_limits_fm_mtm7;

-- Display one tile. ST_DumpAsPolygons() unions identical values together.
SELECT (ST_DumpAsPolygons(rast)).*
FROM a_elevation_fm_10x10_wgs84
WHERE rid = 194265;

-- Display one tile. ST_PixelAsPolygons() dumps all individual pixels.
SELECT (ST_PixelAsPolygons(rast)).*
FROM a_elevation_fm_10x10_wgs84
WHERE rid = 194265;

-- Check size of the biggest tables
SELECT nspname || '.' || relname AS "relation",
       pg_size_pretty(pg_total_relation_size(C.oid)) AS "total_size"
FROM pg_class C
LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace)
WHERE nspname NOT IN ('pg_catalog', 'information_schema')
      AND C.relkind <> 'i'
      AND nspname !~ '^pg_toast'
ORDER BY pg_total_relation_size(C.oid) DESC
LIMIT 50;

--------------------------------------------
-- 5.1) Extraction from RASTER for POINTS 
--------------------------------------------
-- Extract the elevation for each point. 3s
--DROP TABLE IF EXISTS h_random_points_fm_1000_elev_mtm7;
CREATE TABLE h_random_points_fm_1000_elev_mtm7 AS
SELECT id, 
       geom, 
       avg(ST_Value(rast, ST_Transform(geom, 4326))) elev -- Get the pixel value under the projected point (or the average of elevations if the point fall on the border of many pixels)
FROM f_random_points_fm_1000_mtm7, a_elevation_fm_10x10_wgs84
WHERE ST_Intersects(rast, ST_Transform(geom, 4326)) -- Check if the tile extent intersects with the projected geometry
GROUP BY id, geom;

-- Display in OpenJump or QGIS (in WGS 84)
SELECT id, elev, ST_Transform(geom, 4326) geom
FROM h_random_points_fm_1000_elev_mtm7;

-----------------------------------------------------------------------------
-- Why do we reproject geometries to the raster srid and not the opposite?
-----------------------------------------------------------------------------
-- Reproject the raster tiles
SELECT rid, ST_Transform(rast, 32187)::geometry geom
FROM a_elevation_fm_100x100_wgs84;

SELECT (ST_DumpAsPolygons(ST_Transform(rast, 32187))).*
FROM a_elevation_fm_100x100_wgs84
WHERE rid = 100 OR rid = 101;

-- We have to ST_Union() raster coverages BEFORE reprojecting them (and then retile it).
-- Sometimes it is not possible because they are too big...
CREATE TABLE a_elevation_fm_100x100_mtm7 AS
SELECT ST_Tile(ST_Transform(ST_Union(rast), 32187), 100, 100) rast
FROM a_elevation_fm_100x100_wgs84;

-- Add a unique rid to each tile
SELECT ST_AddUniqueID('a_elevation_fm_100x100_mtm7', 'rid');

-- Look at the tile footprints
SELECT rid, rast::geometry geom
FROM a_elevation_fm_100x100_mtm7;

-- Look at some tiles
SELECT (ST_DumpAsPolygons(rast)).*
FROM a_elevation_fm_100x100_mtm7
WHERE rid = 429 OR rid = 430;

-- Reextract the elevation for each point. some point might get a different value because of the raster reprojection.
--DROP TABLE IF EXISTS h_random_points_fm_1000_elev_mtm7;
CREATE TABLE h_random_points_fm_1000_elev_mtm7_2 AS
SELECT id, 
       geom, 
       avg(ST_Value(rast, geom)) elev -- Get the pixel value under the projected point
FROM f_random_points_fm_1000_mtm7, a_elevation_fm_100x100_mtm7
WHERE ST_Intersects(rast, geom) -- Check if the tile extent intersects with the projected geometry
GROUP BY id, geom;

---------------------------------------------------------------
-- 5.2) Extraction from RASTER for POLYGONS (VECTOR MODE)
--      - Raster tiles are vectorized and then intersected with the polygons
--      - Good when polygon sizes are relatively smaller than the pixel size
--        or when the vector coverage is composed of lines
--      - Slower than the raster mode, but more (too much) precise.
---------------------------------------------------------------
-- Intersect each buffer with the elevation in vector mode. 2 minutes
--DROP TABLE IF EXISTS h_random_buffers_fm_1000_elev_mtm7;
CREATE TABLE h_random_buffers_fm_1000_elev_mtm7 AS
WITH rast_geom_inter AS (
  SELECT id, 
         ST_Intersection(rast, ST_Transform(geom, 4326)) gv -- Intersect the vectorized tile with the geometry returning geomval records
  FROM g_random_buffers_fm_1000_mtm7, a_elevation_fm_20x20_wgs84
  WHERE ST_Intersects(rast, ST_Transform(geom, 4326)) -- Check if the tile extent intersects with the projected geometry
)
SELECT id, 
       (gv).val elev,
       ST_Transform((gv).geom, 32187) geom, 
       ST_Area(ST_Transform((gv).geom, 32187)) area -- Project the geometry in MTM before computing the area
FROM rast_geom_inter;

-- Display as table
SELECT * 
FROM h_random_buffers_fm_1000_elev_mtm7;

-- Display in OpenJump or QGIS
SELECT id, elev, ST_Transform(geom, 4326) geom, area
FROM h_random_buffers_fm_1000_elev_mtm7;

---------------------------------------------------------------
-- 5.2.1) Intersect and aggregate per buffer. 30s
---------------------------------------------------------------
--DROP TABLE IF EXISTS h_random_buffers_fm_1000_stats_wgs84;
CREATE TABLE h_random_buffers_fm_1000_stats_wgs84 AS
WITH rast_geom_inter AS (
  SELECT id, 
         ST_Intersection(rast, ST_Transform(geom, 4326)) gv
  FROM g_random_buffers_fm_1000_mtm7, a_elevation_fm_10x10_wgs84
  WHERE ST_Intersects(rast, ST_Transform(geom, 4326))
)
SELECT id, (ST_AreaWeightedSummaryStats(gv)).* -- Aggregate geomval parts
FROM rast_geom_inter
GROUP BY id;

-- Display as table and in OpenJump or QGIS
SELECT * 
FROM h_random_buffers_fm_1000_stats_wgs84;

-- PROBLEM: All the area are computed in degree!
-- SOLUTION: Reproject the intersection parts in 32187 before aggregating...
--DROP TABLE IF EXISTS h_random_buffers_fm_1000_stats_wgs84;
CREATE TABLE h_random_buffers_fm_1000_stats_wgs84 AS
WITH rast_geom_inter AS (
  SELECT id, 
         ST_Intersection(rast, ST_Transform(geom, 4326)) gv
  FROM g_random_buffers_fm_1000_mtm7, a_elevation_fm_10x10_wgs84
  WHERE ST_Intersects(rast, ST_Transform(geom, 4326))
)
SELECT id, (ST_AreaWeightedSummaryStats(ST_Transform((gv).geom, 32187), (gv).val)).* -- Aggregate geomval parts
FROM rast_geom_inter
GROUP BY id;

-- Display
SELECT * 
FROM h_random_buffers_fm_1000_stats_wgs84;

------------------------------------------------------------------------
-- 5.3) Extraction from RASTER for POLYGONS (RASTER MODE with ST_Clip())
--      - Raster tiles are clipped to the polygon extent and then summarized
--      - Good when polygon sizes are much bigger than the pixel size
--      - Works only when extracting for polygons 
--      - Faster than the vector mode, but less precise (pixels are not cut, 
--        take all or leave)
------------------------------------------------------------------------

------------------------------------------------------------------------
-- Load the limits of the province of Quebec
-- shp2pgsql -s 4269 -W LATIN1 -I "D:\Formations\PostGIS\04 - FOSS4G 2017\Attendees\data\limits_QC\limits_QC.shp" "a_limits_qc_nad83" | psql -U "postgres" -d "FOSS4G2017"

-- Display in OpenJump or QGIS
SELECT * 
FROM a_limits_qc_nad83;

------------------------------------------------------------------------
-- Load elevation raster files covering the province out-db
-- raster2pgsql -R -F -I -C -x "D:\Formations\PostGIS\04 - FOSS4G 2017\Attendees\data\srtm\tif\*.tif" a_elevation_qc_wgs84_out | psql -U postgres -d "FOSS4G2017"
-- Each pixel is 60m x 100m. There are 13 6000x6000 pixels rasters for a total of 468 000 000 pixels.

-- Display metadatas
SELECT (ST_Metadata(rast)).*, (ST_BandMetadata(rast)).*
FROM a_elevation_qc_wgs84_out;

-- Display them
SELECT rast::geometry
FROM a_elevation_qc_wgs84_out;

-- Retile to 46800 100x100 tiles. 500ms
--DROP TABLE IF EXISTS g_elevation_qc_100x100_wgs84_out;
CREATE TABLE a_elevation_qc_100x100_wgs84_out AS
SELECT ST_Tile(rast, 100, 100) rast
FROM a_elevation_qc_wgs84_out;

-- Index it.
CREATE INDEX a_elevation_qc_100x100_wgs84_out_rast_gist ON a_elevation_qc_100x100_wgs84_out USING gist (ST_ConvexHull(rast));

-- Add a unique identifier to each tile. 3s
SELECT ST_AddUniqueID('a_elevation_qc_100x100_wgs84_out', 'rid', true);

-- Add all constraints except the "min extent" one. 7s
SELECT AddRasterConstraints('a_elevation_qc_100x100_wgs84_out', 'rast', true, true, true, true, true, true, false, true, true, true, true, false);

-- Display the tiles in OpenJump or QGIS
SELECT rid, rast::geometry
FROM a_elevation_qc_100x100_wgs84_out;

-- Display one tile
SELECT (ST_DumpAsPolygons(rast)).*
FROM a_elevation_qc_100x100_wgs84_out
WHERE rid = 29701;

------------------------------------------------------------------------
-- Create one thousand 2000m buffers in the province. 1s
--DROP TABLE IF EXISTS i_random_buffers_qc_1000_wgs84;
CREATE TABLE i_random_buffers_qc_1000_wgs84 AS
SELECT ST_Transform(ST_Buffer(ST_Transform(ST_RandomPoints(ST_Union(geom), 1000, 0), 32187), 2000), 4326) geom
FROM a_limits_qc_nad83;

CREATE INDEX i_random_buffers_qc_1000_wgs84_geom_gist ON i_random_buffers_qc_1000_wgs84 USING gist (geom);

-- Add a unique identifier to each point
SELECT ST_AddUniqueID('i_random_buffers_qc_1000_wgs84', 'id', true);

-- Display in OpenJump or QGIS
SELECT *
FROM i_random_buffers_qc_1000_wgs84;

------------------------------------------------------------------------------------------------
-- Actual query - Clip and summarise the elevation tiles for all 1000 buffers. 5s
------------------------------------------------------------------------------------------------
--DROP TABLE IF EXISTS i_random_buffers_qc_1000_elevstats_wgs84;
CREATE TABLE i_random_buffers_qc_1000_elevstats_wgs84 AS
SELECT id, 
       ST_Union(geom) geom, -- Union polygons that were splitted over two tiles or more
       (ST_SummaryStatsAgg(ST_Clip(rast, geom, true), true, 1)).* -- Crop tiles to the extent of the geometry and aggregate the statistics by polygon id
FROM a_elevation_qc_100x100_wgs84_out, i_random_buffers_qc_1000_wgs84
WHERE ST_Intersects(rast, geom)
GROUP BY id;

-- Display as table
SELECT * 
FROM i_random_buffers_qc_1000_elevstats_wgs84;

-- Display the clipping of the tiles in OpenJump or QGIS. 17s
SELECT id, ST_Clip(rast, geom, true)::geometry
FROM g_elevation_qc_100x100_wgs84_out, i_random_buffers_qc_1000_wgs84
WHERE ST_Intersects(rast, geom);

------------------------------------------------------
-- 6) Elevation Profile
------------------------------------------------------
-- Load the road network
-- shp2pgsql -s 4269:32187 -W LATIN1 -I "D:\Formations\PostGIS\04 - FOSS4G 2017\Attendees\data\roads\roads.shp" "a_roads_fm_mtm7" | psql -U "postgres" -d "FOSS4G2017"

-- Add a unique identifier to each route. 1s
SELECT ST_AddUniqueID('a_roads_fm_mtm7', 'id', true, true);

-- Display them in OpenJump or QGIS
SELECT *
FROM a_roads_fm_mtm7;

------------------------------------------------------
-- 6.1) Elevation Profile
------------------------------------------------------

-- Create one point every 100m along the main road
WITH road AS (
  SELECT ST_LineMerge(ST_Union(geom)) geom
  FROM a_roads_fm_mtm7 
  WHERE toponyme = '175'
)
SELECT id, 
       id * 100 length, 
       ST_LineInterpolatePoint(geom, id/(ST_Length(geom)/100)) geom
FROM generate_series(0, (SELECT ST_Length(geom)/100 FROM road)::int) id, road;

-- Alternative: Create 100 points along the main road
WITH road AS (
  SELECT ST_LineMerge(ST_Union(geom)) geom
  FROM a_roads_fm_mtm7 
  WHERE toponyme = '175'
)
SELECT id, 
       round((id * ST_Length(geom)::numeric)/99, 1) length, 
       ST_LineInterpolatePoint(geom, id/99.0) geom
FROM generate_series(0, 99) id, road;

-- Extract the elevation for each 100 points
--DROP TABLE IF EXISTS j_elevation_profile_mtm7_main_road;
CREATE TABLE j_elevation_profile_mtm7_main_road AS
WITH road AS (
  SELECT ST_LineMerge(ST_Union(geom)) geom
  FROM a_roads_fm_mtm7 
  WHERE toponyme = '175'
), points AS (
  SELECT id, 
         round((id * ST_Length(geom)::numeric)/99, 1) length, 
         ST_LineInterpolatePoint(geom, id/99.0) geom
  FROM generate_series(0, 99) id, road
)
SELECT id, geom, length, 
       ST_Value(rast, ST_Transform(geom, 4326)) elev
FROM points, a_elevation_fm_10x10_wgs84
WHERE ST_Intersects(rast, ST_Transform(geom, 4326));

-- Display in OpenJump or QGIS
SELECT id, length, elev, ST_Transform(geom, 4326) geom 
FROM j_elevation_profile_mtm7_main_road;

-- Display all the pixels underneath the road
WITH tiles AS (
  SELECT DISTINCT rast
  FROM a_elevation_fm_10x10_wgs84, j_elevation_profile_mtm7_main_road
  WHERE ST_Intersects(rast, ST_Transform(geom, 4326))
)
SELECT (ST_DumpAsPolygons(rast)).*
FROM tiles;

-- Export in CSV and create an histogram in Excel
COPY j_elevation_profile_mtm7_main_road TO '/temp/elevation_profile_main_road.csv' DELIMITER ',' CSV HEADER;

------------------------------------------------------
-- 6.2) Elevation Profile (with interpolation)
------------------------------------------------------

-- Select the longest road part
SELECT id, ST_Length(geom) length
FROM a_roads_fm_mtm7
ORDER BY length DESC
LIMIT 1;

-- Display it in mtm7
SELECT id, geom 
FROM a_roads_fm_mtm7 
WHERE id = 1806;

-- Display it in wgs84
SELECT id, ST_Transform(geom, 4326) geom 
FROM a_roads_fm_mtm7 
WHERE id = 1806;

-- Extract the elevation for each point
-- PROBLEM: Many subsequent points get the same elevation resulting in a jagged line
--DROP TABLE IF EXISTS j_elevation_profile_mtm7_small_part_no_interp;
CREATE TABLE j_elevation_profile_mtm7_small_part_no_interp AS
WITH road AS (
  SELECT (ST_Dump(geom)).geom 
  FROM a_roads_fm_mtm7 
  WHERE id = 1806
), points AS (
  SELECT id, 
         round((id * ST_Length(geom)::numeric)/99, 1) length, 
         ST_LineInterpolatePoint(geom, id/99.0) geom
  FROM generate_series(0, 99) id, road
)
SELECT id, geom, length, 
       ST_Value(rast, ST_Transform(geom, 4326)) elev
FROM points, a_elevation_fm_10x10_wgs84
WHERE ST_Intersects(rast, ST_Transform(geom, 4326));

-- Export in CSV and create an histogram in Excel
COPY j_elevation_profile_mtm7_small_part_no_interp TO '/temp/elevation_profile_small_part_no_interp.csv' DELIMITER ',' CSV HEADER;

-- Determine the pixel size in MTM 7
SELECT SQRT(ST_Area(ST_Transform(ST_PixelAsPolygon(rast, 1, 1), 32187))) size
FROM a_elevation_fm_10x10_wgs84
LIMIT 1;

-- Extract the elevation for each point
--DROP TABLE IF EXISTS j_elevation_profile_mtm7_small_part_with_interp;
CREATE TABLE j_elevation_profile_mtm7_small_part_with_interp AS
WITH road AS (
  SELECT (ST_Dump(geom)).geom 
  FROM a_roads_fm_mtm7 
  WHERE id = 1806
), buffers AS (
  SELECT id, 
         round((id * ST_Length(geom)::numeric)/99, 1) length, 
         ST_LineInterpolatePoint(geom, id/99.0) geom
  FROM generate_series(0, 99) id, road
), rast_geom_inter AS (
  SELECT id, length, geom,
         ST_Intersection(rast, ST_Transform(ST_Buffer(geom, 74/2), 4326)) gv
  FROM buffers, a_elevation_fm_10x10_wgs84
  WHERE ST_Intersects(rast, ST_Transform(ST_Buffer(geom, 74/2), 4326))
)
SELECT id, geom, length, 
       (ST_AreaWeightedSummaryStats(ST_Transform((gv).geom, 32187), (gv).val)).weightedmean elev -- Aggregate geomval parts
FROM rast_geom_inter
GROUP BY id, length, geom;

-- Display in OpenJump or QGIS
SELECT id, elev, ST_Transform(geom, 4326) geom 
FROM j_elevation_profile_mtm7_small_part_with_interp;

-- Export in CSV and create an histogram in Excel
COPY j_elevation_profile_mtm7_small_part_with_interp TO '/temp/elevation_profile_small_part_with_interp.csv' DELIMITER ',' CSV HEADER;


------------------------------------------------------
-- 4) Nearest Neighbour
------------------------------------------------------
-- Generate 3 000 000 random points inside limits_fm. 42s
--DROP TABLE IF EXISTS k_random_points_fm_3000000_mtm7;
CREATE TABLE k_random_points_fm_3000000_mtm7 AS
SELECT generate_series(1, 3000000) id, 
       ST_RandomPoints(ST_Union(geom), 3000000, 1) geom 
FROM a_limits_fm_mtm7;

-- Add a spatial index on the points. 40s
CREATE INDEX k_random_points_fm_3000000_mtm7_geom_gist ON k_random_points_fm_3000000_mtm7 USING gist (geom);

-- Add an index on id
CREATE INDEX k_random_points_fm_3000000_mtm7_id ON k_random_points_fm_3000000_mtm7 (id);

-- Display the 3 000 000 points in OpenJump or QGIS
SELECT * 
FROM k_random_points_fm_3000000_mtm7;

------------------------------------------------------
-- 4.1) Nearest Neighbour - For 1 POINT from 1 000 000 POINTS. Classic method with and without ST_DWithin.
------------------------------------------------------
-- Display the 1 000 points we will search neighbours for in OpenJump or QGIS
SELECT * 
FROM f_random_points_fm_1000_mtm7;

-- Display the one point we are interested in
SELECT * 
FROM f_random_points_fm_1000_mtm7
WHERE id = 146;

-- Without ST_DWithin(). 2s
SELECT pointB.geom, 
       pointB.id, 
       ST_Distance(pointA.geom, pointB.geom) dist
FROM f_random_points_fm_1000_mtm7 pointA, 
     k_random_points_fm_3000000_mtm7 pointB
WHERE pointA.id = 146 
ORDER BY dist
LIMIT 3;

-- With ST_DWithin(). 30ms
SELECT pointB.geom, 
       pointB.id, 
       ST_Distance(pointA.geom, pointB.geom) dist
FROM f_random_points_fm_1000_mtm7 pointA, 
     k_random_points_fm_3000000_mtm7 pointB
WHERE pointA.id = 146 AND 
      ST_DWithin(pointA.geom, pointB.geom, 8) -- ST_DWithin() is fast because it uses the index. PROBLEM: Try with id = 673 to realize that 8 meter is not enough. What is enough?
ORDER BY dist
LIMIT 3;

-- Try to find the biggest third smallest distance. Takes a long time (20 minutes) because needs to compute way too many distances (1000 * 3000000).
-- (Can not be written as a Common Table Expressions (WITH statement))
SELECT pointA.*, -- Get the biggest smallest
       (SELECT dist -- Get the third furthest
        FROM (SELECT ST_Distance(pointA.geom, pointB.geom) dist -- Find the four nearest points (include the point itself)
              FROM k_random_points_fm_3000000_mtm7 pointB
              ORDER BY dist ASC
              LIMIT 4) foo
        ORDER BY dist DESC
        LIMIT 1)
FROM f_random_points_fm_1000_mtm7 pointA
ORDER BY dist DESC
LIMIT 1;

------------------------------------------------------
-- 4.2) Nearest Neighbour - For 1 POINT from 1 000 000 POINTS. KNN method.
------------------------------------------------------
SELECT id, 
       geom, 
       (SELECT geom FROM f_random_points_fm_1000_mtm7 WHERE id = 146) <-> near_point.geom dist
FROM k_random_points_fm_3000000_mtm7 near_point
ORDER BY dist
LIMIT 3;

-- Pre PostgreSQL 9.5 equivalent query. When <-> was not returning the true distance.
SELECT near_point.id, 
       near_point.geom, 
       ST_Distance(point.geom, near_point.geom) dist
FROM f_random_points_fm_1000_mtm7 point, 
     k_random_points_fm_3000000_mtm7 near_point
WHERE point.id = 146
ORDER BY (SELECT geom 
          FROM f_random_points_fm_1000_mtm7 
          WHERE id = 146) <-> near_point.geom -- Try with 673. No problem!
LIMIT 3;

------------------------------------------------------
-- 4.3) Nearest Neighbour - For 1000 POINT from 3 000 000 POINTS. KNN method using LATERAL JOIN (PG 9.3+).
------------------------------------------------------
SELECT pointA.id, 
       pointA.geom, 
       near_point.id near_id,
       near_point.geom near_geom,
       near_point.dist
FROM f_random_points_fm_1000_mtm7 pointA, LATERAL
     (SELECT pointB.id, 
             pointB.geom, 
             pointB.geom <-> pointA.geom dist
      FROM k_random_points_fm_3000000_mtm7 pointB
      ORDER BY dist
      LIMIT 3
     ) near_point;

-- Display as table
SELECT * 
FROM k_random_points_fm_3nearest_1000_mtm7_lateral;

------------------------------------------------------
-- 4.4) Nearest Neighbour - For 1000 POINT from 6200 POLYLINES.
------------------------------------------------------
-- Display all the routes in OpenJump or QGIS
SELECT * 
FROM a_roads_fm_mtm7;

-- Find the first nearest road. PG 9.5+
SELECT point.id, 
       point.geom, 
       near_road.id nearest_road_id,
       near_road.geom nearest_road_geom,
       near_road.dist
FROM f_random_points_fm_1000_mtm7 point, LATERAL
     (SELECT road.id, 
             road.geom, 
             road.geom <-> point.geom dist
      FROM a_roads_fm_mtm7 road
      ORDER BY dist
      LIMIT 1) near_road
ORDER BY point.id, near_road.dist;

-- Pre-PG 9.5 Two Step Approach. When <-> was not returning the true distance.
WITH first30bb AS (
  SELECT point.id, 
         point.geom, 
         near_road.nearest_road_id, 
         near_road.geom nearest_road_geom,
         near_road.dist
  FROM f_random_points_fm_1000_mtm7 point, LATERAL
       (SELECT road.id nearest_road_id, 
               road.geom,
               ST_Distance(road.geom, point.geom) dist
        FROM a_roads_fm_mtm7 road
        ORDER BY road.geom <#> point.geom
        LIMIT 30) near_road
  ORDER BY point.id, dist
),
ordered AS ( -- Make groups of ordered dist, one for each id
  SELECT *, 
         ROW_NUMBER() OVER (PARTITION BY id ORDER BY dist) rownum 
  FROM first30bb
) -- Get only the first (nearest) one for each group
SELECT * 
FROM ordered WHERE rownum < 2;


------------------------------------------------------
-- 5.1) MapAlgebra - Aggregate RASTERS together.
------------------------------------------------------
-- Display the Montmorency Forest in OpenJump or QGIS in WGS84
SELECT ST_Transform(geom, 4326) geom 
FROM a_limits_fm_mtm7;

-- Create a buffered version of the Forest Monmorency limits
--DROP TABLE IF EXISTS l_limits_fm_200m_mtm7;
CREATE TABLE l_limits_fm_200m_mtm7 AS
SELECT ST_Buffer(geom, 200) geom
FROM a_limits_fm_mtm7;

-- Display the buffered version
SELECT ST_Transform(geom, 4326) geom 
FROM l_limits_fm_200m_mtm7;

-- Display tiles intersecting with Montmorency Forest
SELECT rid, rast::geometry geom
FROM a_elevation_fm_10x10_wgs84, l_limits_fm_200m_mtm7
WHERE ST_Intersects(rast, ST_Transform(geom, 4326));

-- Merge them into a one row raster.
--DROP TABLE IF EXISTS l_elevation_fm_wgs84;
CREATE TABLE l_elevation_fm_wgs84 AS
SELECT ST_Union(rast) rast
FROM a_elevation_fm_10x10_wgs84, l_limits_fm_200m_mtm7
WHERE ST_Intersects(rast, ST_Transform(geom, 4326));

-- Display the extent of the new raster 
SELECT rast::geometry 
FROM l_elevation_fm_wgs84;

-- Display avectorization of the new raster 
SELECT (ST_DumpAsPolygons(rast)).* 
FROM l_elevation_fm_wgs84;

------------------------------------------------------
-- 5.2) MapAlgebra - Compute HillShade.
------------------------------------------------------
-- Reproject the unioned raster
--DROP TABLE IF EXISTS m_elevation_fm_mtm7;
CREATE TABLE m_elevation_fm_mtm7 AS
SELECT ST_Transform(rast, 32187) rast
FROM l_elevation_fm_wgs84;

-- Double chech the SRID
SELECT ST_SRID(rast) srid 
FROM m_elevation_fm_mtm7;

-- Display its extent.
SELECT rast::geometry 
FROM m_elevation_fm_mtm7;

-- Display the limits
SELECT * 
FROM a_limits_fm_mtm7;

-- Display the values
SELECT (ST_DumpAsPolygons(rast)).* 
FROM m_elevation_fm_mtm7;

-- Compute the hillshade raster. 5s
--DROP TABLE IF EXISTS m_hillshade_fm_mtm7;
CREATE TABLE m_hillshade_fm_mtm7 AS
SELECT ST_HillShade(rast, 1, '32BF', 180) rast
FROM m_elevation_fm_mtm7;

-- Display in OpenJump or QGIS
SELECT (ST_DumpAsPolygons(rast)).* 
FROM m_hillshade_fm_mtm7;

------------------------------------------------------
-- 5.3) MapAlgebra - Reclass hillshade into 20 classes using ST_MapAlgebra. 100ms
------------------------------------------------------
-- Display the min and max of the unclassified hillshade raster.
SELECT (ST_SummaryStats(rast)).* 
FROM m_hillshade_fm_mtm7;

--DROP TABLE IF EXISTS m_hillshade_fm_20class_mtm7_ma;
CREATE TABLE m_hillshade_fm_20class_mtm7_ma AS
SELECT ST_SetBandNodataValue(ST_MapAlgebra(rast, '8BUI', 
   'CASE
      WHEN 0 <= [rast] AND [rast] <= 150 THEN round(10 * [rast] / 150.0)
      WHEN 150 < [rast] AND [rast] <= 254 THEN 10 + round(10 * ([rast] - 150)/(254 - 150))
      ELSE 255
    END', 255), 255) rast
FROM m_hillshade_fm_mtm7;

-- Compare the metadata before and after. Look at the pixel types and nodatavalue.
SELECT (ST_Metadata(rast)).*, (ST_BandMetadata(rast)).* FROM m_hillshade_fm_mtm7
UNION ALL
SELECT (ST_Metadata(rast)).*, (ST_BandMetadata(rast)).* FROM m_hillshade_fm_20class_mtm7_ma

-- Compare the statistics before and after reclass. Look at the min and max.
SELECT (ST_SummaryStats(rast)).* FROM m_hillshade_fm_mtm7
UNION ALL
SELECT (ST_SummaryStats(rast)).* FROM m_hillshade_fm_20class_mtm7_ma;

-- Display in OpenJump or QGIS
SELECT (ST_DumpAsPolygons(rast)).* 
FROM m_hillshade_fm_20class_mtm7_ma;

------------------------------------------------------
-- 5.3) MapAlgebra - Reclass hillshade into 20 classes using ST_Reclass(). 30ms
------------------------------------------------------
--DROP TABLE IF EXISTS m_hillshade_fm_20class_mtm7;
CREATE TABLE m_hillshade_fm_20class_mtm7 AS
SELECT ST_Reclass(rast, ROW(1, '0-150:0-10, (150-254: 10-20', '8BUI', 255)::reclassarg) rast
FROM m_hillshade_fm_mtm7;

-- Compare the metadata of all three raster. Both reclassified rasters are identical.
SELECT 'm_hillshade_fm_mtm7'::text hillshade_table, (ST_Metadata(rast)).*, (ST_BandMetadata(rast)).* FROM m_hillshade_fm_mtm7
UNION ALL
SELECT 'm_hillshade_fm_20class_mtm7_ma', (ST_Metadata(rast)).*, (ST_BandMetadata(rast)).* FROM m_hillshade_fm_20class_mtm7_ma
UNION ALL
SELECT 'm_hillshade_fm_20class_mtm7', (ST_Metadata(rast)).*, (ST_BandMetadata(rast)).* FROM m_hillshade_fm_20class_mtm7;

-- Compare the statistics...
SELECT 'm_hillshade_fm_mtm7'::text hillshade_table, (ST_SummaryStats(rast)).* FROM m_hillshade_fm_mtm7
UNION ALL
SELECT 'm_hillshade_fm_20class_mtm7_ma', (ST_SummaryStats(rast)).* FROM m_hillshade_fm_20class_mtm7_ma
UNION ALL
SELECT 'm_hillshade_fm_20class_mtm7', (ST_SummaryStats(rast)).* FROM m_hillshade_fm_20class_mtm7;

------------------------------------------------------
-- 6.1) Rasterization - POLYGON to RASTER. ST_AsRaster(), ST_Union() and ST_MapAlgebra() method.
------------------------------------------------------

-- Display the forest cover
SELECT * 
FROM a_forestcover_mtm7;

-- Create a 10x10 tiled version of m_elevation_fm_mtm7 limited to the forest extent
--DROP TABLE IF EXISTS n_elevation_fm_10x10_mtm7;
CREATE TABLE n_elevation_fm_10x10_mtm7 AS
SELECT rast
FROM (SELECT ST_Tile(rast, 10, 10) rast 
      FROM m_elevation_fm_mtm7) foo,
     l_limits_fm_200m_mtm7
WHERE ST_Intersects(rast, geom);

-- Index it.
CREATE INDEX n_elevation_fm_10x10_mtm7_rast_gist ON n_elevation_fm_10x10_mtm7 USING gist (st_convexhull(rast));

-- Add an id.
SELECT ST_AddUniqueID('n_elevation_fm_10x10_mtm7', 'rid', true, true);

-- Display tiling
SELECT rid, rast::geometry 
FROM n_elevation_fm_10x10_mtm7;

-- Create one raster per geometry aligned on the elevation grid
SELECT rid, gid, (ST_DumpAsPolygons(ST_AsRaster(geom, rast, '32BF', height, -9999), 1, false)).*
FROM a_forestcover_mtm7, 
     n_elevation_fm_10x10_mtm7
WHERE ST_Intersects(geom, rast) --AND gid = 6529;

-- Union them all as one big raster and display it
WITH rast_union AS (
  SELECT ST_Union(ST_AsRaster(geom, rast, '32BF', height, -9999)) rast
  FROM a_forestcover_mtm7, 
       n_elevation_fm_10x10_mtm7
  WHERE ST_Intersects(geom, rast)
)
SELECT (ST_DumpAsPolygons(rast)).*
FROM rast_union;
  
-- Rasterize the forest cover height. 4s
-- Steps are:
-- 1) Rasterize every polygon as a single raster with ST_AsRaster()
-- 2) Union all these raster together into a single big raster with ST_Union()
-- 3) Cut this raster to the extent of each tile from the elevation coverage using ST_MapAlgebra() and a JOIN with the elevation coverage
-- 4) Create an empty tile when no rasterized geometry intersect with the tile ST_AddBand(ST_MakeEmptyRaster()) and LEFT JOIN
--
-- Pros: - Fast
-- Cons: - Only the value at pixel centroids can be extracted (GDAL)
--       - Only basic metrics (like the means of values) can be computed when many pixels overlaps (with ST_Union)
-- 
--DROP TABLE IF EXISTS n_forestheight_fm_10x10_mtm7;
CREATE TABLE n_forestheight_fm_10x10_mtm7 AS
WITH forestrast AS (
  SELECT rid, ST_MapAlgebra( -- Make sure rasterized geometries cover a full tile
                ST_Union(ST_AsRaster(geom, rast, '32BF', height, -9999)), -- Create one raster per geometry aligned on the elevation coverage and union them all
                ST_AddBand(ST_MakeEmptyRaster(rast), '32BF'::text, -9999, -9999), -- Recreate an empty nodata band similar to the elevation tile
                '[rast1]', -- Take the value from the first raster (produced with ST_AsRaster). Could actually be null since value are defined by the last parameter because the second raster is always nodata...
                '32BF',    -- Make a 32 bit float raster
                'SECOND',  -- Take the extent from the second raster (so we make one raster per elevation tile)
                NULL,      -- Set the pixel value to nodata when rast1 is nodata
                '[rast1]'  -- Set the pixel value to rast1 when rast2 is nodata (which is always the case)
                ) rast
  FROM a_forestcover_mtm7, 
       n_elevation_fm_10x10_mtm7
  WHERE ST_Intersects(geom, rast)
  GROUP BY rid, rast
)
SELECT a.rid,
       CASE -- Make sure all tiles are returned. When no geometry intersect a tile, return en empty tile (filled with nodata) (it's not the case here...).
         WHEN b.rid IS NULL THEN ST_AddBand(ST_MakeEmptyRaster(a.rast), '32BF'::text, -9999, -9999)
         ELSE b.rast
       END rast
FROM n_elevation_fm_10x10_mtm7 a LEFT OUTER JOIN forestrast b 
ON a.rid = b.rid;

-- Display tiles in OpenJump or QGIS
SELECT rast::geometry 
FROM n_forestheight_fm_10x10_mtm7;

-- Display pixels in OpenJump or QGIS
SELECT (ST_DumpAsPolygons(rast)).* 
FROM n_forestheight_fm_10x10_mtm7;

------------------------------------------------------
-- 6.2) Rasterization - POLYGON to RASTER. PostGIS Addons ST_ExtractToRaster() method.
------------------------------------------------------
-- Rasterize using PostGIS Addons ST_ExtractToRaster(). 26s
-- Each pixel is vectorized and intersected with the vector coverage extracting metrics following the specified method.
--
-- Pros: - Many metrics are already implemented (look at the PostGIS Addons file)
--       - Easy to add more metrics
--       - Metrics can be based on the contriod of the pixel or on its extent
-- Cons: - Slower than the ST_AsRaster(), ST_Union() and ST_MapAlgebra() method.
--
--DROP TABLE IF EXISTS o_forestheight_fm_10x10_mergedbiggest_mtm7;
CREATE TABLE o_forestheight_fm_10x10_mergedbiggest_mtm7 AS
SELECT rid, ST_ExtractToRaster( 
                    ST_AddBand(
                        ST_MakeEmptyRaster(rast), '32BF'::text, -9999, -9999), 
                    'public', 
                    'a_forestcover_mtm7', 
                    'geom', 
                    'height', 
                    'VALUE_OF_MERGED_BIGGEST'
                  ) rast 
FROM n_elevation_fm_10x10_mtm7;

-- Display pixels in OpenJump or QGIS
SELECT rid, (ST_DumpAsPolygons(rast)).* 
FROM o_forestheight_fm_10x10_mergedbiggest_mtm7
ORDER BY rid;

------------------------------------------------------
-- 5.5) MapAlgebra - Add a RASTER to another RASTER.
------------------------------------------------------
-- Add the cover height to the elevation only when the tiles perfectly overlap. 2s
--DROP TABLE IF EXISTS p_canopyheight_10x10_mtm7_ma;
CREATE TABLE p_canopyheight_10x10_mtm7_ma AS
SELECT ST_MapAlgebra(e.rast, fc.rast, '[rast1] + [rast2]', '32BF', 'INTERSECTION', '[rast2]', '[rast1]') rast
FROM n_elevation_fm_10x10_mtm7 e, 
     o_forestheight_fm_10x10_mergedbiggest_mtm7 fc
WHERE ST_UpperLeftX(e.rast) = ST_UpperLeftX(fc.rast) AND ST_UpperLeftY(e.rast) = ST_UpperLeftY(fc.rast);

-- Display pixels in OpenJump or QGIS. Display NULL pixels as well.
SELECT (ST_DumpAsPolygons(rast, 1, false)).* 
FROM p_canopyheight_10x10_mtm7_ma;

-- Samething but with ST_Union(). 150 ms.
--DROP TABLE IF EXISTS p_canopyheight_10x10_mtm7_union;
CREATE TABLE p_canopyheight_10x10_mtm7_union AS
SELECT ST_Union(rast, 'SUM') rast 
FROM (SELECT ST_MapAlgebra(rast, '32BF', '[rast]') rast FROM n_elevation_fm_10x10_mtm7 -- Change the pixel type of elevation from 16BSI to 32BF
      UNION ALL
      SELECT rast FROM o_forestheight_fm_10x10_mergedbiggest_mtm7
     ) foo
GROUP BY ST_UpperLeftX(rast), ST_UpperLeftY(rast);

