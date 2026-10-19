#package CloudAtlas::SelectorQueries;
#use Dancer2::Plugin::Database;
#our $VERSION = '0.1';
#use Dancer2 appname => 'CloudAtlas::Main';
#all above mess not needed 'cause we load this code with "require"


sub get_display {
	my $knot_id=shift;
	my $sth=database('knots')->prepare("
	select bounds.sub,b2.ord as duration,knots.*
 from bounds join bounds as b2 on b2.sub=bounds.sub and b2.predicate='display_duration' join knots on knots.knot_id=bounds.sub where bounds.bound_id=(select bound_id from bounds where predicate='display_priority' and ord>=(select random()*max(ord) from bounds where predicate='display_priority') and obj=? order by random() limit 1)
	");
	$sth->execute($knot_id);
	return $sth->fetchrow_hashref();
}

sub get_subtree {
	my $knot_id=shift;
	my $sth=database('knots')->prepare("
		WITH RECURSIVE knots_descendants(parent_id, child_id, depth, label, labelpath, knot_content, attributes)
		AS                                                                                                  
		( SELECT sub, obj, 1::INT AS depth, knot_name as label, '' AS labelpath, knot_content, attributes  FROM bounds left join knots on knots.knot_id=obj WHERE sub = ?
		UNION ALL SELECT c.sub, c.obj, p.depth + 1 AS depth, knot_name as label, (p.labelpath || '->' || label), knots.knot_content, knots.attributes FROM knots_descendants AS p, bounds AS c left join knots on c.obj=knots.knot_id WHERE c.sub = child_id
		) select * from knots_descendants
	");
	$sth->execute($knot_id);
	return $sth->fetchall_arrayref({});
}


sub get_zeitgeist {
	# $offset used to be silently accepted and then ignored (the query had
	# no OFFSET clause at all) -- now a row offset, so /zeitgeist/<n> can
	# actually page past the first 230 instead of always returning the same
	# ones, which is what infinite-scroll "load more" needs.
	my $offset = shift || 0;
	my $sth=database('knots')->prepare("select zeitgeist.*,knot_name as agent from zeitgeist join knots on agent_id=knot_id order by action_executed desc limit 230 offset ?");
	$sth->execute($offset);
	return $sth->fetchall_arrayref({});
}
sub get_last_knot_with_name {
	my $knot_name = shift;
	#my $sth=database('knots')->prepare("select * from knots where knot_name like ? order by knot_id limit 1");
	my $sth=database('knots')->prepare("select * from knots where knot_name = ? order by knot_id desc limit 1");
	$sth->execute($knot_name);
	#return $sth->fetchrow_hashref();
	return attach_attributes($sth->fetchall_arrayref({}))->[0];
}

sub get_first_knot_with_referer {
	my $knot_name = shift;
	#debug "REFERER $knot_name";
	# referer is a single value ("memes") or a comma-separated list of
	# aliases ("meme,memetics,memplex"), any one of which should resolve to
	# this knot -- split the stored attribute on commas (trimming stray
	# whitespace around each alias) and match the requested name against any
	# element, so a plain single-value referer keeps working exactly as before.
	my $sth=database('knots')->prepare("
		select * from knots
		where exists (
			select 1 from unnest(string_to_array(attributes->'referer', ',')) as alias
			where trim(alias) = ?
		)
		order by knot_id limit 1
	");
	$sth->execute($knot_name);
	my $aref=$sth->fetchall_arrayref({});
	return attach_attributes($aref)->[0];
}

sub get_first_knot_with_name {
	my $knot_name = shift;
	#my $sth=database('knots')->prepare("select * from knots where knot_name like ? order by knot_id limit 1");
	my $sth=database('knots')->prepare("select * from knots where knot_name = ? order by knot_id limit 1");
	#$sth->execute('%'.$knot_name.'%');
	$sth->execute($knot_name);
	#return $sth->fetchrow_hashref();
	my $aref=$sth->fetchall_arrayref({});
	use Data::Dumper;
	#debug Dumper($aref->[0]);
	return attach_attributes($aref)->[0];
}
sub get_bounds {
	# same fix as get_zeitgeist -- $offset was accepted and discarded before
	my $offset = shift || 0;
	my $sth=database('knots')->prepare("
		select bound_id,subs.knot_name as sub_name, subs.knot_id as sub_id, objs.knot_name as obj_name, objs.knot_id as obj_id, predicate, bound_created,ord from bounds left join knots as subs on subs.knot_id=sub left join knots as objs on objs.knot_id=obj order by bound_created desc limit 100 offset ?");
	$sth->execute($offset);
	return $sth->fetchall_arrayref({});
}

sub get_bookmarks {
	my $user_id = shift;
	my $sth=database('knots')->prepare("select objs.knot_name as obj_name, objs.knot_id as obj_id, predicate, ord from bounds left join knots as objs on objs.knot_id=obj where predicate='has_bookmark' and sub = ? order by ord desc");
	$sth->execute($user_id);
	return $sth->fetchall_arrayref({});
}



sub get_child_attribute_matrix {
	my $knot_id = shift;
	my @attz = qw(Schriftname Gestaltung Jahr);
	my $q1="";
	foreach $a (@attz) {
		$q1.=",child.attributes->'$a' as $a";
	}
	#debug $q;
	my $sth=database('knots')->prepare("select child.knot_id, child.knot_name, child.attributes->'Schriftname' as Schriftname,child.attributes->'Gestaltung' as Gestaltung,child.attributes->'Jahr' as Jahr from bounds left join knots as child on child.knot_id=bounds.obj where sub=? and predicate='is_parent' order by Jahr,Schriftname");
	my $q="select child.knot_id, child.knot_name, $q1 from bounds left join knots as child on child.knot_id=bounds.obj where sub=895 and predicate='is_parent'";
	#my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return $sth->fetchall_arrayref({});
}


sub get_search {
	my $query = shift;
	my $order = shift;
	$order = "desc" if !$order;
	my $sth=database('knots')->prepare("select attributes, knot_id, knot_name, substring(knot_content from 0 for 777) as knot_content from  knots where knot_name ~* ? or knot_content ~* ? order by knot_id desc");
	#my $q="select knot_id, knot_name, substring(knot_content from 0 for 777) as knot_content from  knots where knot_name ~* $query or knot_content ~* $query order by knot_id desc";
	#debug "QUERY $q";
	$sth->execute($query,$query);
	return attach_attributes $sth->fetchall_arrayref({});
}



sub get_last {
	my $offset = shift || 0;
	my $sth=database('knots')->prepare("select knot_id, knot_name, substring(knot_content from 0 for 777) as knot_content,
		attributes->'img_url' as img_url,
		attributes->'embed_url' as embed_url,
		attributes->'video_url' as video_url,
		attributes->'screenshot_url' as screenshot_url
		 from  knots order by knot_id desc limit 42 offset ?");
	$sth->execute($offset);
	return $sth->fetchall_arrayref({});
}

sub get_bounds_by_obj_predicate {
	my $knot_id = shift;
	my $predicate = shift;
	$predicate = 'is_parent' if (!$predicate);
	my $sth=database('knots')->prepare("
		select * from bounds left join knots on sub=knot_id where obj=? and predicate=?
		order by sub desc
	");
	$sth->execute($knot_id,$predicate);
	return $sth->fetchall_arrayref({});
}
#this procedure can be removed
sub get_display_relations {
	my $knot_id = shift;
	my $sth=database('knots')->prepare("
		select * from bounds left join knots on sub=knot_id where obj=? and predicate='display_priority' or predicate='display_duration'
		order by sub desc
	");
	$sth->execute($knot_id);
	return $sth->fetchall_arrayref({});
}



sub get_knot {
	my $knot_id = shift;
	my $sth=database('knots')->prepare("select * from knots where knot_id = ?");
	$sth->execute($knot_id);
	return attach_attributes($sth->fetchall_arrayref({}))->[0];
	#return $sth->fetchrow_hashref();
}

sub get_by_object {
	my $knot_id = shift;
	my $sth=database('knots')->prepare("select bounds.*,knots.knot_content as subject_content,knots.attributes as attributes,knots.knot_name as subject_name, knots.knot_id as subject_id from  bounds left join knots on knots.knot_id = bounds.sub where obj = ? order by bounds.ord limit 500");
	$sth->execute($knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
}

sub get_zeitgeist_by_knot {
	my $knot_id = shift;
	return if $knot_id!~/^\d+$/; #SQLinjection prevention, placeholders with hstore difficult
	my $sth=database('knots')->prepare("select zeitgeist.*,knot_name as agent from zeitgeist left join knots on agent_id=knot_id where vars->'knot_id' = '$knot_id' or vars->'obj'='$knot_id' or vars->'sub'='$knot_id' or action='/view/$knot_id/' order by action_executed desc");
	$sth->execute;
	return $sth->fetchall_arrayref({});
}


sub get_by_subject {
	my $knot_id = shift;
	my $sth=database('knots')->prepare("select bounds.*, knots.knot_name as object_name, knots.attributes as attributes,knots.knot_id as object_id,knots.knot_content as object_content from  bounds left join knots on knots.knot_id = bounds.obj where sub = ? order by bounds.ord limit 3000");
	$sth->execute($knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
}

sub get_grandchildren_sample {
	my $knot_id=shift;
	my $q="select distinct on (children.knot_id)
                children.ord,children.knot_id as parent_id, '2' as depth,
                bounds.ord as ord2,
                children.knot_name as parent,
                grandchildren.knot_id as id,
                grandchildren.knot_name as name,
                grandchildren.knot_content as content,
                grandchildren.attributes->'img_url' as img_url                                                                                                                                 		from  (select children.*,bounds.* from bounds left join knots as children on children.knot_id=bounds.obj 
	where sub=? and predicate='is_parent' order by random()) 
	children left join bounds on bounds.sub=children.knot_id and bounds.predicate='is_parent' left join knots as grandchildren on bounds.obj=grandchildren.knot_id where  bounds.ord>0 order by children.knot_id,random()";
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return $sth->fetchall_arrayref({});
}

sub get_grandchildren_audiotext {
        my $knot_id=shift;
	#debug "AUDIOTEXT $knot_id";
        my $q="select distinct on (children.knot_id)
                children.ord,children.knot_id as parent_id, '2' as depth,
                bounds.ord as ord2,
                children.knot_name as parent,
                grandchildren.knot_id as id,
                grandchildren.knot_name as name,
                grandchildren.attributes->'ogg_url' as ogg_url,
                grandchildren.knot_content as content,
                grandchildren.attributes->'img_url' as img_url                                                                                                                                          from  (select children.*,bounds.* from bounds left join knots as children on children.knot_id=bounds.obj 
        where sub=? and predicate='is_parent' order by random()) 
        children left join bounds on bounds.sub=children.knot_id and bounds.predicate='is_uttered_as' left join knots as grandchildren on bounds.obj=grandchildren.knot_id where  bounds.ord>0 order by children.knot_id,random()";
        my $sth=database('knots')->prepare($q);
        $sth->execute($knot_id);
        return $sth->fetchall_arrayref({});
}

sub get_children {
	my $knot_id=shift;
	my $q="select children.*,bounds.*,children.attributes->'img_url' as img_url  from bounds left join knots as children on children.knot_id=bounds.obj  where sub=? and predicate='is_parent' order by bounds.ord";
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return $sth->fetchall_arrayref({});
}

sub get_all_public_knots {
	my $knot_id=shift;
	my $q="select knot_name from knots where attributes->'public'='1'";
	my $sth=database('knots')->prepare($q);
	$sth->execute();
	return $sth->fetchall_arrayref({});
}

sub get_2generations {
	my $knot_id=shift;
	my $periode=shift;
	my $q="
		(select
		children.ord,children.knot_id as parent_id, '2' as depth,
		bounds.ord as ord2,
		children.knot_name as parent,
		grandchildren.knot_id as id,
		grandchildren.knot_name as name,
		grandchildren.knot_content as content,
		grandchildren.attributes->'lehrender' as lehrender, 
		grandchildren.attributes->'raum' as raum, 
		grandchildren.attributes->'tag' as tag,
		grandchildren.attributes->'uhrzeit' as uhrzeit,
		grandchildren.attributes->'email' as email,
		grandchildren.attributes->'credits' as credits,
		grandchildren.attributes->'periode' as periode, 
		grandchildren.attributes->'typ' as typ,
		grandchildren.attributes->'kum_typ' as kum_typ,
		grandchildren.attributes->'kum_fontcolor' as kum_fontcolor,
		grandchildren.attributes->'kum_bi' as kum_bi,
		grandchildren.attributes->'img' as img,
		grandchildren.attributes->'angebot' as angebot, 
		grandchildren.attributes->'img_url' as img_url, 
		grandchildren.attributes->'erster_tag' as erster_tag 
 from (select children.*,bounds.* from bounds left join knots as children on children.knot_id=bounds.obj where sub=? and predicate='is_parent' order by ord desc,knot_id) children left join bounds on bounds.sub=children.knot_id left join knots as grandchildren on bounds.obj=grandchildren.knot_id where ";
	$q.=" grandchildren.attributes->'periode' like  ? and" if ($periode);
	$q.=" bounds.ord>0 order by bounds.ord desc,children.ord desc,children.knot_id asc)
		UNION (
		select ord,children.knot_id as parent_id, '1' as depth,
		1 as ord2,
		'' as parent,
		children.knot_id as id,
		children.knot_name as name,
		children.knot_content as content,
		'' as lehrender, 
		'' as raum, 
		'' as tag,
		'' as uhrzeit,
		'' as email,
		'' as credits,
		'' as periode,
		'' as typ,
		'' as kum_typ,
		children.attributes->'kum_fontcolor' as kum_fontcolor,
		children.attributes->'kum_bi' as kum_bi,
		children.attributes->'img' as img,
		children.attributes->'img_url' as img_url,
		'' as angebot,
		children.attributes->'erster_tag' as erster_tag
		from bounds left join knots as children on children.knot_id=bounds.obj where sub=? and ord>0 order by ord desc,knot_id 
		) 
		order by ord desc,parent_id,depth,ord2 desc,typ
";

	my $sth=database('knots')->prepare($q);
	$periode ? $sth->execute($knot_id,$periode,$knot_id) : $sth->execute($knot_id,$knot_id);
	return $sth->fetchall_arrayref({});
}

sub get_knot_info {
	my $knot_id=shift;
        my $sth=database('knots')->prepare("select parent.knot_id as parent_id, knots.* from knots left join bounds on knots.knot_id=bounds.obj and predicate='is_parent' left join knots as parent on bounds.sub=parent.knot_id where knots.knot_id=?");
	$sth->execute($knot_id);
	return $sth->fetchrow_hashref;
}


sub get_attribute {
	my $attribute=shift;
	my $knot_id=shift;
	#debug "GETING $attribute for $knot_id";
	my $sth=database('knots')->prepare("select knots.attributes->'ogg_url' as attribute from knots where knot_id=?");
	$sth->execute($knot_id);
	my ($var) = $sth->fetchrow_array()   and $sth->finish();
	#debug("select knots.attributes->'ogg_url' as attribute from knots where knot_id=$knot_id");
	#my ($var) = database('knots')->selectrow_array("select knots.attributes->'ogg_url' as attribute from knots where knot_id=$knot_id");
	#debug($var);
	return $var;
}

sub get_ogg {
	my $knot_id=shift;
	#debug "GETING OGG for $knot_id";
	my $sth=database('knots')->prepare("select rec.attributes->'ogg_url' as ogg_url from bounds left join knots as rec on rec.knot_id=bounds.obj where bounds.sub=? and bounds.predicate='is_uttered_as' order by random() limit 1");
	$sth->execute($knot_id);
	return $sth->fetchrow_hashref->{'ogg_url'};
}

sub get_portfolio_by_artist {
        my $artist = shift;
        $q="select *,attributes->'periode' as periode,attributes->'img' as img,attributes->'img_url' as img_url,attributes->'kum_typ' as kum_typ,attributes->'periode' as periode from knots where attributes->'artist' ilike ? order by knot_id desc";
        debug "QUERY $q $artist";
        my $sth=database('knots')->prepare($q);
        $sth->execute("%".$artist."%");
	#return $sth->fetchall_arrayref({});
	return attach_attributes($sth->fetchall_arrayref({}));
}

true;
