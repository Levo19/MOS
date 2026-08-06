CREATE OR REPLACE FUNCTION wh._claim_ok()
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select coalesce(me.jwt_app(),'') in ('', 'warehouseMos');
$function$
