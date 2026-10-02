#Interface between Kastalia's Core and Template Toolkit.
#please ask DDH for consent if You want to use this code (notably the SQL queries) for own projects
use Template::Stash;
use Time::HiRes qw(time);
use JSON::XS;

use POSIX qw(strftime);
use feature 'unicode_strings';
use utf8;

# Function to remove HTML tags
$Template::Stash::SCALAR_OPS->{remove_html_tags} = sub {
    my $text = shift;
    $text =~ s/<[^>]+>//g;
    return $text;
};

# knot_name often carries its whole materialized path baked in (either
# "/"-separated, as baumhaus.tt already strips via knot_name.split('/').last,
# or "++"-separated elsewhere in the graph) -- strip everything up to and
# including the last separator, keeping just the leaf segment.
sub _short_name {
	my $name = shift;
	return $name unless defined $name;
	(my $short = $name) =~ s/^.*(?:\+\+|\/)//;
	return $short;
}
$Template::Stash::SCALAR_OPS->{short_name} = sub { return _short_name(shift); };

# The "epoch" knot attribute is a unix timestamp; Core.pm's attach_attributes
# already turns that into an "AE......" anno-epoche label and a plain date,
# but only for objects/subjects (dendrite) rows -- the center knot itself
# only gets a raw Pg::hstore::decode, no derived fields. Same algorithm,
# exposed as template filters so any knot's own epoch attribute can use it.
$Template::Stash::SCALAR_OPS->{epoch_to_ae} = sub {
	my $epoch = shift;
	return undef unless defined $epoch && $epoch =~ /^\d+$/;
	my @t = localtime($epoch);
	my $year = $t[5] - 70;
	my $suffix = strftime('%m%d', @t);
	return 'AE' . $year . $suffix;
};
$Template::Stash::SCALAR_OPS->{epoch_to_date} = sub {
	my $epoch = shift;
	return undef unless defined $epoch && $epoch =~ /^\d+$/;
	my @t = localtime($epoch);
	return strftime('%d.%m.%Y', @t);
};

# Full ancestor breadcrumb(s): a knot can have more than one is_parent bound
# pointing to it (a genuine multi-parent DAG, not a strict tree), so this
# returns one chain PER DIRECT PARENT rather than silently collapsing to a
# single path -- every one of a knot's direct parents is real and should be
# shown, not just the "strongest" one. Above that immediate-parent level we
# do still climb via a single deterministic (highest-ord) parent per step,
# to avoid a full combinatorial explosion of every branch at every level;
# in practice direct multi-parenting is what actually happens in this graph,
# and further-up branching is rare. Cycle-guarded and depth-capped like
# get_labyrinth. Each returned chain is root-most first, direct-parent last.
$Template::Stash::SCALAR_OPS->{get_ancestor_chain} = sub {
	my $knot_id   = shift;
	my $max_depth = shift || 10;
	$max_depth = 20 if $max_depth > 20;

	my $parents_sth = database('knots')->prepare("
		select subj.knot_id as id, subj.knot_name as name
		from bounds b join knots subj on subj.knot_id = b.sub
		where b.obj = ? and b.predicate = 'is_parent' and b.ord > 0
		order by b.ord desc, subj.knot_id asc
	");
	my $single_parent_sth = database('knots')->prepare("
		select subj.knot_id as id, subj.knot_name as name
		from bounds b join knots subj on subj.knot_id = b.sub
		where b.obj = ? and b.predicate = 'is_parent' and b.ord > 0
		order by b.ord desc, subj.knot_id asc
		limit 1
	");

	$parents_sth->execute($knot_id);
	my @direct_parents = @{ $parents_sth->fetchall_arrayref({}) };
	return [] unless @direct_parents;

	my @chains;
	for my $p (@direct_parents) {
		my @chain = ({ id => $p->{id} + 0, name => _short_name($p->{name}) });
		my %seen = ($knot_id + 0 => 1, $p->{id} + 0 => 1);
		my $current = $p->{id};
		for (1..$max_depth - 1) {
			$single_parent_sth->execute($current);
			my $row = $single_parent_sth->fetchrow_hashref;
			last unless $row;
			last if $seen{$row->{id} + 0};
			$seen{$row->{id} + 0} = 1;
			unshift @chain, { id => $row->{id} + 0, name => _short_name($row->{name}) };
			$current = $row->{id};
		}
		push @chains, \@chain;
	}
	return \@chains;
};

# Function to escape LaTeX special characters
$Template::Stash::SCALAR_OPS->{escape_latex} = sub {
    my $text = shift;
    $text =~ s/([&%$\#_{}~^\\])/\\$1/g;
    $text =~ s/\\\s+/\\ /g;
    return $text;
};

# Function to clean image paths
$Template::Stash::SCALAR_OPS->{clean_image_path} = sub {
    my $path = shift;
    $path =~ s{data/img/}{};
    return $path;
};

$Template::Stash::SCALAR_OPS->{process} = sub {
	my $token=shift;
	$token=~s/,$/''/g;
	$token=~s/\t/''/g;
	#$token=~s/(\w)\x{0259}(\w)?/<span style='color:orange'>\1e\2<\/span>/g;
	$token=~s/(\w)\x{0259}(\w)?/\1e\2/g;
	$token=~s/(\w)\x{0250}(\w)?/\1e\2/g;
	#$token=~s/_//g;
	#$token=~s/\/\1LAL\1/g;
	return $token;
};
$Template::Stash::SCALAR_OPS->{tokenize} = sub {
	my $sequence=shift;
	debug $token;
	my $tokens="";
	my $phrase="";
	$sequence=~s/_/ /g;
	while ($sequence=~/"w":"(.*?)"/g) {
		debug $1;
		if ($1 ne ' ') {
			$tokens.=$1."\n";
			#$phrase.=$1." ";
		}
	}
	return $tokens;
};
$Template::Stash::SCALAR_OPS->{get_session_key} = sub {
	my $k= shift;
	my $sd=session->data;
	#debug("GETTING SESSIONKEY ".$k." ".$sd->{$k});
	return $sd->{$k};
};	
$Template::Stash::SCALAR_OPS->{decode_html} = sub {
	use HTML::Entities;
	return decode_entities(shift);
};

$Template::Stash::SCALAR_OPS->{get_language_flag} = sub {
	my $langcode=shift;
	if ($langcode eq 'de') {
		return "🇩🇪";
	}
	if ($langcode eq 'en') {
		return "🇬🇧";
	}
	if ($langcode eq 'sk') {
		return "🇸🇰";
	}
	if ($langcode eq 'es') {
		return "🇪🇸";
	}


};

$Template::Stash::SCALAR_OPS->{get_words} = sub {
	use HTML::Entities;
	my $words=decode_entities(shift);
	#debug $words;
	my $i=0;
	my @a;
	$words=~s/[^[:print:]]+//g;
	$words=~s/([_^\W]+)/ \1 /g;
	$words=~s/"(.*?)"/ \x{201E} $1 \x{201C} /g;
	push @a,(split / +/,$words);
	
	return @a;
};

$Template::Stash::SCALAR_OPS->{get_words_tenfold} = sub {
	use HTML::Entities;
	my $words=decode_entities(shift);
	#debug $words;
	my $i=0;
	my @a;
	$words=~s/[^[:print:]]+//g;
	$words=~s/([_^\W]+)/ \1 /g;
	push @a,(split / +/,$words);
	#return grep {!/_/} @a;
	my @multiplied;
	for my $i (1..10) {
		foreach my $a (@a) {
			push(@multiplied,$a);
		}
	}
	return @multiplied;
};

$Template::Stash::SCALAR_OPS->{get_last_knots} = sub {
	my $limit=shift;
	my $q="select * from knots order by knot_id desc limit ?";
	my $sth=database('knots')->prepare($q);
	$sth->execute($limit);
	return attach_attributes $sth->fetchall_arrayref({});
};

$Template::Stash::SCALAR_OPS->{get_subtree_json} = sub {
	my $knot_id=shift;
	my $q="select jsonb_pretty(build_family) from build_family(?)";
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return $sth->fetchrow_hashref;
};

$Template::Stash::SCALAR_OPS->{get_plain_knot} = sub {
	my $knot_id=shift;
	my $q="select * from knots where knot_id=?";
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
};

$Template::Stash::SCALAR_OPS->{get_foliae} = sub {
	my $knot_id=shift;
	my $q="select distinct on (parent_bound.sub) knots.knot_id as knot_id,knots.knot_name,knots.knot_content as content,knots.attributes as attributes,string_agg(distinct illustration.knot_name,'::') as illustration_names,string_agg(distinct illustration.attributes->'img_url','::') as illustration_urls from bounds as parent_bound left join knots on parent_bound.obj=knots.knot_id and parent_bound.predicate='contains' left join bounds on knots.knot_id=bounds.obj left join knots as illustration on bounds.sub=illustration.knot_id and bounds.predicate='illustrates' where parent_bound.sub=?  group by knots.knot_id,knots.knot_name,knots.knot_content,knots.attributes,parent_bound.ord order by parent_bound.ord asc,knots.knot_id;";
	debug $q;
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
};
$Template::Stash::SCALAR_OPS->{get_children_with_illustrations} = sub {
	my $knot_id=shift;
	#my $q="select knots.knot_id as knot_id,replace(substring(knots.knot_name from '(?<=\\+\\+)[^+]*\$'),'_','') as short_name,knots.knot_name,knots.knot_content as content,knots.attributes as attributes,string_agg(distinct illustration.knot_name,'::') as illustration_names,string_agg(distinct illustration.attributes->'img_url','::') as illustration_urls from bounds as parent_bound left join knots on parent_bound.obj=knots.knot_id and parent_bound.predicate='is_parent' left join bounds on knots.knot_id=bounds.obj left join knots as illustration on bounds.sub=illustration.knot_id and bounds.predicate='illustrates' where parent_bound.sub=?  group by knots.knot_id,knots.knot_name,knots.knot_content,knots.attributes,parent_bound.ord order by parent_bound.ord asc,knots.knot_id;";
	my $q="select knots.knot_id as knot_id,replace(substring(knots.knot_name from '(?<=\\+\\+)[^+]*\$'),'_','') as short_name,knots.knot_name,knots.knot_content as content,knots.attributes as attributes,json_agg(distinct illustration.knot_name) as illustration_names,json_agg(distinct illustration.attributes->'img_url') as illustration_urls,json_agg(distinct '/audio/'||audios.knot_id||'.ogg') as ogg_urls from bounds as parent_bound left join knots on parent_bound.obj=knots.knot_id and parent_bound.predicate='is_parent' left join bounds on knots.knot_id=bounds.obj left join knots as illustration on bounds.sub=illustration.knot_id and bounds.predicate='illustrates' left join bounds as audio_bounds on knots.knot_id=audio_bounds.sub and audio_bounds.predicate='is_uttered_as' left join knots as audios on audio_bounds.obj=audios.knot_id where parent_bound.sub=?  group by knots.knot_id,knots.knot_name,knots.knot_content,knots.attributes,parent_bound.ord order by parent_bound.ord asc,knots.knot_id;";
	#debug $q;
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
};


$Template::Stash::SCALAR_OPS->{get_illustration} = sub {
	my $knot_id=shift;
	#print "$knot_id START".time();
	my $q="select string_agg(distinct illustration.attributes->'img_url','::') as illustration_urls from bounds as parent_bound left join knots as parent on parent.knot_id=parent_bound.sub and (parent_bound.predicate='is_parent' or parent_bound.predicate='is_uttered_as') left join knots as child on child.knot_id=parent_bound.obj left join bounds as illustration_bound on parent.knot_id=illustration_bound.obj and illustration_bound.predicate='illustrates' left join knots as illustration on illustration.knot_id=illustration_bound.sub where parent_bound.obj=?";
	debug $q;
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	my $res=$sth->fetchrow_hashref();
	#debug "$knot_id END".time();
	return $res->{'illustration_urls'};
};

$Template::Stash::SCALAR_OPS->{get_bdlp} = sub {
	my $knot_id=shift;
	my $q="select members.knot_name from bounds left join knots as members on members.knot_id=bounds.sub where bounds.obj=? and bounds.predicate='is_member' order by random() limit 4";
	my $sth=database('knots')->prepare($q);
	#debug "select bounds.sub,recording.knot_content,string_agg(distinct recording.attributes->'ogg_url','::') as recording_urls from bounds left join knots as recording on recording.knot_id=bounds.obj where bounds.predicate='is_uttered_as' and bounds.sub in (select members.knot_id from bounds left join knots as members on members.knot_id=bounds.sub and bounds.predicate='is_member' where bounds.obj='knot_id') group by recording.knot_content,bounds.sub order by random() limit 4";
	$sth->execute($knot_id);
	#return attach_attributes $sth->fetchall_arrayref({});
	return $sth->fetchall_arrayref({});
};


$Template::Stash::SCALAR_OPS->{get_distinct_voices} = sub {
	my $knot_id=shift;
	#my $q="select recordings.attributes as attributes, recordings.knot_id as recording_id from bounds left join knots as recordings on bounds.obj=recordings.knot_id where predicate='is_uttered_as' and sub=?";
	my $q="select distinct on (recordings.attributes->'voice') recordings.attributes,recordings.knot_id as recording_id from bounds left join knots as recordings on bounds.obj=recordings.knot_id where predicate='is_uttered_as' and sub=?";
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
	#return $sth->fetchall_arrayref({});
};


$Template::Stash::SCALAR_OPS->{get_voices} = sub {
	my $knot_id=shift;
	#my $q="select recordings.attributes as attributes, recordings.knot_id as recording_id from bounds left join knots as recordings on bounds.obj=recordings.knot_id where predicate='is_uttered_as' and sub=?";
	my $q="select recordings.attributes,recordings.knot_id as recording_id,recordings.knot_name as recording_name from bounds left join knots as recordings on bounds.obj=recordings.knot_id where predicate='is_uttered_as' and sub=?";
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
	#return $sth->fetchall_arrayref({});
};

$Template::Stash::SCALAR_OPS->{get_newest_child } = sub {
	my $knot_id=shift;
	my $q="select children.*,bounds.*,extract(epoch from children.knot_created at time zone 'cest') as epoch from bounds left join knots as children on children.knot_id=bounds.obj where sub=? and predicate='is_parent' order by knot_created desc limit 1";
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
};
$Template::Stash::SCALAR_OPS->{get_voicevariants} = sub {
	my $knot_id=shift;
	#my $q="select source,json_agg(e) from (select variant.attributes->'voice' as voice,variant.attributes->'autx_content' as autx_content, variant.attributes->'ogg_url' as ogg_url,variants.obj as variant_id,source.obj as source from bounds as source left join bounds as vorlage on source.obj=vorlage.obj and vorlage.predicate='is_uttered_as' left join bounds as variants on vorlage.sub=variants.sub and variants.predicate='is_uttered_as' left join knots as variant on variant.knot_id=variants.obj where source.sub=? and variant.attributes->'voice' is not null) e group by source";
	#where sub=? and predicate=\'is_parent\' and ord>0
	#my $q="select max(e.source_ord) as mes,vorlage.attributes->'difficulty' as difficulty,e.vorlage_id,vorlage.knot_content as vorlage_content,json_agg(e),count(e.voice) from (select distinct on (voice,source_ord,vorlage_id) vorlage.sub as vorlage_id,source.ord as source_ord,variant.attributes->'voice' as voice,variant.attributes->'autx_content' as autx_content,variants.obj as variant_id,source.obj as source from bounds as source left join knots as source_knot on source.sub=source_knot.knot_id left join bounds as vorlage on source.obj=vorlage.obj and vorlage.predicate='is_uttered_as' left join bounds as variants on vorlage.sub=variants.sub and variants.predicate='is_uttered_as' and variants.ord>0 left join knots as variant on variant.knot_id=variants.obj where source.sub=? and source.predicate='contains' and length(variant.attributes->'ogg_url')>0 and (variant.attributes->'voice' != source_knot.attributes->'voice-filter' or source_knot.attributes->'voice-filter' is null)) e left join knots as vorlage on vorlage.knot_id=e.vorlage_id group by e.vorlage_id,vorlage_content,difficulty order by difficulty,mes,vorlage_id desc";
	my $q="select distinct on (voice,source_ord,vorlage_id,source) source_knot.knot_content as vorlage_content,vorlage.sub as vorlage_id,source.ord as source_ord,variant.attributes->'voice' as voice,variant.attributes->'autx_content' as autx_content,variants.obj as variant_id,source.obj as source from bounds as source left join knots as source_knot on source.sub=source_knot.knot_id left join bounds as vorlage on source.obj=vorlage.obj and vorlage.predicate='is_uttered_as' left join bounds as variants on vorlage.sub=variants.sub and variants.predicate='is_uttered_as' and variants.ord>0 left join knots as variant on variant.knot_id=variants.obj where source.sub=? and source.predicate='contains' and length(variant.attributes->'ogg_url')>0 and (variant.attributes->'voice' != source_knot.attributes->'voice-filter' or source_knot.attributes->'voice-filter' is null) order by source_ord,source";
	my $sth=database('knots')->prepare($q);
	debug $q;
	$sth->execute($knot_id);
	return $sth->fetchall_arrayref({});
};

$Template::Stash::SCALAR_OPS->{get_arbre} = sub {
	my $knot_id=shift;
	my $q="with recursive tree as (
	  select obj,
		 sub,
		 predicate,
		 array[obj] as ancestor_ids,
		 array[knot_name] as ancestor_names
	  from bounds left join knots on obj=knot_id
	  where sub=? and ord>0
	  union all
	  select c.obj,
		 c.sub,
		 p.predicate,
		 p.ancestor_ids||c.obj,
		 p.ancestor_names || knot_name
	  from bounds c
	     join tree p
	      on c.sub = p.obj
	      and p.predicate='is_parent'
	     and c.obj <> ALL (p.ancestor_ids) -- avoids endless loops
	     left join knots on c.obj=knot_id and c.ord>0
		      )
	select ancestor_names,ancestor_ids as knot_id
	from tree where predicate='is_parent' order by ancestor_names";
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
	#return $sth->fetchall_arrayref({});
};


$Template::Stash::SCALAR_OPS->{get_children_rand} = sub {
	my $knot_id=shift;
	my $q="select children.knot_id as knot_id,children.knot_name as knot_name,children.knot_content as knot_content,bounds.* from bounds left join knots as children on children.knot_id=bounds.obj where sub=? and predicate='is_parent' order by random()";
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
};
# create list op vmethod, sorry its pretty trivial
$Template::Stash::SCALAR_OPS->{get_children} = sub {
	my $knot_id=shift;
	my $q="select children.*,bounds.* from bounds left join knots as children on children.knot_id=bounds.obj where sub=? and predicate='is_parent' order by bounds.ord,knot_id desc";
	debug $q;
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
};

# create list op vmethod, sorry its pretty trivial
$Template::Stash::SCALAR_OPS->{get_children_roulette} = sub {
	my $knot_id=shift;
	my $q="select children.*,bounds.* from bounds left join knots as children on children.knot_id=bounds.obj where sub=? and predicate='is_parent' order by random()*bounds.ord asc";
	#debug $q;
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
};


$Template::Stash::SCALAR_OPS->{get_contained} = sub {
	my $knot_id=shift;
	my $q="select children.*,bounds.* from bounds left join knots as children on children.knot_id=bounds.obj where sub=? and predicate='contains' order by ord desc,children.attributes->'epoch' desc";
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
};

$Template::Stash::SCALAR_OPS->{get_children_in_space} = sub {
	my $knot_id=shift;
	my $q="select Xb.ord as X_coordinate,Yb.ord as Y_coordinate,Zb.ord as Z_coordinate,children.*,bounds.* from bounds left join knots as children on children.knot_id=bounds.obj left join bounds as Xb on Xb.sub=bounds.sub and Xb.obj=bounds.obj and Xb.predicate='contains_at_X_coordinate' left join bounds as Yb on Yb.sub=bounds.sub and Yb.obj=bounds.obj and Yb.predicate='contains_at_Y_coordinate' left join bounds as Zb on Zb.sub=bounds.sub and Zb.obj=bounds.obj and Zb.predicate='contains_at_Z_coordinate'  where bounds.sub=? and bounds.predicate='is_parent'";
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
};


$Template::Stash::SCALAR_OPS->{get_uncurated_grandchildren} = sub {
        my $knot_id=shift;
        my $q="select
                children.ord,children.knot_id as parent_id, '2' as depth,
                bounds.ord as ord2,
                children.knot_name as parent,
                grandchildren.knot_id as knot_id,
                grandchildren.knot_name as name,
                grandchildren.attributes->'ogg_url' as ogg_url,
                grandchildren.knot_content as content,
                grandchildren.attributes->'autx_content' as autx_content              
		from  (select children.*,bounds.* from bounds left join knots as children on children.knot_id=bounds.obj where sub=? and predicate='is_parent') 
        children join bounds on bounds.sub=children.knot_id and bounds.predicate='is_uttered_as' join knots as grandchildren on bounds.obj=grandchildren.knot_id left join bounds as qb on qb.sub=grandchildren.knot_id and qb.predicate='has_quality' and qb.bound_creator=? where qb.obj is NULL order by children.knot_id limit 100";
        my $sth=database('knots')->prepare($q);
        $sth->execute($knot_id,session('user_id'));
        return $sth->fetchall_arrayref({});
};

$Template::Stash::SCALAR_OPS->{get_curated} = sub {
        my $knot_id=shift;
        my $q="select attributes->'ogg_url' as ogg_url from bounds left join knots on knot_id=sub where obj=? and predicate='has_quality'";
	my $sth=database('knots')->prepare($q);
	#debug($q);
        $sth->execute($knot_id);
        return $sth->fetchall_arrayref({});
};



$Template::Stash::SCALAR_OPS->{get_grandchildren_audiotext} = sub {
        my $knot_id=shift;
        my $q="select
                children.ord,children.knot_id as parent_id, '2' as depth,
                bounds.ord as ord2,
                children.knot_name as parent,
                grandchildren.knot_id as knot_id,
                grandchildren.knot_name as name,
                grandchildren.attributes->'ogg_url' as ogg_url,
                grandchildren.knot_content as content,
                grandchildren.attributes->'autx_content' as autx_content              
		from  (select children.*,bounds.* from bounds left join knots as children on children.knot_id=bounds.obj where sub=? and predicate='is_parent') 
        children join bounds on bounds.sub=children.knot_id and bounds.predicate='is_uttered_as' join knots as grandchildren on bounds.obj=grandchildren.knot_id where  bounds.ord>0 order by children.knot_id";
        my $sth=database('knots')->prepare($q);
        $sth->execute($knot_id);
        return $sth->fetchall_arrayref({});
};

$Template::Stash::SCALAR_OPS->{check_HMPL} = sub {
	my $action=shift;
	my $q="select * from zeitgeist where method=? and vars->'state'='COMPLETE' and action_executed>NOW()-interval '20 HOURS' and action=? and agent_id=? order by action_executed desc limit 1";
	#debug($q);
	#database('knots')->trace(2);
	my $sth=database('knots')->prepare($q);
	$sth->execute($action,session('knot_id'),session('user_id'));
	#my $r= $sth->fetchall_arrayref({});
	my $r= $sth->fetchrow_hashref();
	#use Data::Dumper;
	#debug Dumper($r);
	session 'HMPL_phase'=>$action;
	return $r;
};


$Template::Stash::SCALAR_OPS->{get_all_useraudio} = sub {
	my $user=shift;
	debug($user);
	#my $q='select attributes->\'ogg_url\' as ogg_url from knots where knot_name like \'% by iolanda-maitreya-%\'';
	my $q='select attributes->\'ogg_url\' as ogg_url from knots where knot_name like ?';
	debug($q);
	my $sth=database('knots')->prepare($q);
	$sth->execute("% by $user-%");
	my $r= $sth->fetchall_arrayref({});
	use Data::Dumper;
	debug Dumper($r);
	return $r;
};


$Template::Stash::SCALAR_OPS->{get_members} = sub {
	my $knot_id=shift;
	debug "GETTIN MEMBERS OF $knot_id\n";
	my $q="
select state.sub,state.ord,bounds.*, children.knot_id as knot_id,children.knot_name as knot_name,children.knot_content as knot_content,children.attributes as attributes from bounds left join knots as children on children.knot_id=bounds.sub left join bounds as state on children.knot_id=state.obj and state.sub=? and state.predicate='misunderstands' where bounds.obj=? and (state.ord>=0.5 or state.ord IS NULL) and bounds.predicate='is_member' order by bounds.ord,attributes->'difficulty',state.ord,knot_id";
	if (session('HMPL_phase') eq 'TEST') {
		$q=$q." limit 10";
		session 'HMPL_phase'=>'';
	} elsif (session('HMPL_phase') eq 'LEARN') {
		$q=$q." limit 20";
		session 'HMPL_phase'=>'';
	}
	#debug "select state.sub,state.ord,bounds.*, children.knot_id as knot_id,children.knot_name as knot_name,children.knot_content as knot_content,children.attributes as attributes from bounds left join knots as children on children.knot_id=bounds.sub left join bounds as state on children.knot_id=state.obj and state.sub=".session('user_id')." and state.predicate='misunderstands' where bounds.obj=$knot_id and (state.ord>=0.5 or state.ord IS NULL) and bounds.predicate='is_member' order by state.ord desc,bounds.ord desc,knot_id";
	my $sth=database('knots')->prepare($q);
	$sth->execute(session('user_id'),$knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
};


$Template::Stash::SCALAR_OPS->{get_2generations} = sub {
	my $knot_id=shift;
	my $q="
		(select
		children.ord,children.knot_id as parent_id, '2' as depth,
		bounds.ord as ord2,
		children.knot_name as parent_name,
		grandchildren.knot_id as knot_id,
		grandchildren.knot_name as knot_name,
		grandchildren.knot_content as knot_content,
		grandchildren.attributes as attributes
 from (select children.*,bounds.* from bounds left join knots as children on children.knot_id=bounds.obj where sub=? and predicate='is_parent' order by ord asc,knot_id asc) as children left join bounds on bounds.sub=children.knot_id left join knots as grandchildren on bounds.obj=grandchildren.knot_id and bounds.predicate='is_parent' where ";
	$q.=" bounds.ord>0 order by bounds.ord,children.ord,children.knot_id asc)
		UNION (
		select ord,children.knot_id as parent_id, '1' as depth,
		1 as ord2,
		'' as parent_name,
		children.knot_id as knot_id,
		children.knot_name as knot_name,
		children.knot_content as knot_content,
		children.attributes as attributes
		from bounds left join knots as children on children.knot_id=bounds.obj where sub=? and ord>0 and predicate='is_parent' order by ord,knot_id asc
		) 
		order by ord,parent_id desc,depth,ord2
";

	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id,$knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
};
	#3generations do not work yet

$Template::Stash::SCALAR_OPS->{get_materialized_paths} = sub {
	my $knot_name=shift;
	debug $knot_name;
	my $sth=database('knots')->prepare("select knot_id,knot_content,knot_name,attributes->'template' as template from knots where knot_name like ? order by knot_name");
	debug "select knot_id,knot_content,knot_name,attributes->'template' as template from knots where knot_name like '%$knot_name' order by knot_name";
	$sth->execute($knot_name.'%');
	return attach_attributes $sth->fetchall_arrayref({});
};

$Template::Stash::SCALAR_OPS->{get_3generations} = sub {
	my $knot_id=shift;
	#my $q="
	#(select grandchildren.ord,grandchildren.knot_id as gp,grandgrandchildren.knot_id as parent_id, '3' as depth,bounds.predicate as predicate,bounds.ord as ord2,grandchildren.knot_name as parent_name,grandgrandchildren.knot_id as knot_id,grandgrandchildren.knot_name as knot_name,grandgrandchildren.knot_content as knot_content,grandgrandchildren.attributes as attributes from (select grandchildren.*,bounds.* from bounds left join knots as grandchildren on grandchildren.knot_id=bounds.obj and  predicate in ('is_parent') where sub=? order by ord desc,knot_id) grandchildren left join bounds on bounds.sub=grandchildren.knot_id and  bounds.predicate in ('contains')  left join knots as grandgrandchildren on bounds.obj=grandgrandchildren.knot_id where bounds.ord>0 order by bounds.ord,grandchildren.ord,grandchildren.knot_id asc)
	#UNION
	my $q="
(select children.ord,grandchildren.knot_id as gp,children.knot_id as parent_id, '2' as depth,bounds.predicate as predicate,bounds.ord as ord2,children.knot_name as parent_name,grandchildren.knot_id as knot_id,grandchildren.knot_name as knot_name,grandchildren.knot_content as knot_content, grandchildren.attributes as attributes from (select children.*,bounds.* from bounds left join knots as children on children.knot_id=bounds.obj and  predicate in ('is_parent','contains') where sub=? order by ord desc,knot_id) children left join bounds on bounds.sub=children.knot_id and bounds.predicate in ('is_parent','contains') left join knots as grandchildren on bounds.obj=grandchildren.knot_id where bounds.ord>0 order by bounds.ord ,children.ord,children.knot_id asc)
	UNION
(select ord,children.knot_id as gp,children.knot_id as parent_id, '1' as depth,bounds.predicate as predicate,1 as ord2,'' as parent_name,children.knot_id as knot_id,children.knot_name as knot_name,children.knot_content as knot_content,children.attributes as attributes from bounds left join knots as children on children.knot_id=bounds.obj and predicate in ('is_parent','contains')  where sub=? and ord>0 order by ord,knot_id )
order by ord,parent_id,depth,ord2,gp
	";
	debug($q);
	my $sth=database('knots')->prepare($q);
	#$sth->execute($knot_id,$knot_id,$knot_id);
	$sth->execute($knot_id,$knot_id);
	return attach_attributes $sth->fetchall_arrayref({});
};

# get_full_deck: like get_3generations, but walks the is_parent subtree to
# arbitrary depth instead of stopping after two generations -- needed once a
# deck is itself nested ("fractal": a root holding section knots, each
# holding their own detail knots). Flattened depth-first in true document
# order (sorted on a zero-padded path of each level's ord, not knot_id, so
# sibling order is correct regardless of creation order) -- a single-page
# viewer like kolleg.tt can render every leaf in order no matter how deep.
$Template::Stash::SCALAR_OPS->{get_full_deck} = sub {
	my $knot_id   = shift;
	my $max_depth = shift || 6;
	$max_depth = 8 if $max_depth > 8;

	my $sth = database('knots')->prepare("
		WITH RECURSIVE tree(id, depth, sortpath) AS (
			SELECT k.knot_id, 0, ''::text
			FROM knots k WHERE k.knot_id = ?
			UNION ALL
			SELECT b.obj, t.depth + 1, t.sortpath || lpad(b.ord::text, 8, '0') || '.'
			FROM tree t
			JOIN bounds b ON b.sub = t.id AND b.predicate = 'is_parent' AND b.ord > 0
			WHERE t.depth < ?
		)
		SELECT k.*, tree.depth
		FROM tree JOIN knots k ON k.knot_id = tree.id
		WHERE tree.depth > 0
		ORDER BY tree.sortpath
	");
	$sth->execute($knot_id, $max_depth);
	return attach_attributes $sth->fetchall_arrayref({});
};

# get_chronological: the full is_parent subtree again, but ordered by each
# knot's own 'epoch' attribute instead of tree position -- a feed/log view
# rather than a document view. $direction 'desc' (default) reads newest
# first (a samizdat-style feed); 'asc' reads oldest first (a voyage log).
$Template::Stash::SCALAR_OPS->{get_chronological} = sub {
	my $knot_id   = shift;
	my $direction = shift || 'desc';
	my $limit     = shift || 60;
	$direction = ($direction eq 'asc') ? 'asc' : 'desc';

	my $sth = database('knots')->prepare("
		WITH RECURSIVE tree(id, depth) AS (
			SELECT k.knot_id, 0 FROM knots k WHERE k.knot_id = ?
			UNION ALL
			SELECT b.obj, t.depth + 1
			FROM tree t
			JOIN bounds b ON b.sub = t.id AND b.predicate = 'is_parent' AND b.ord > 0
			WHERE t.depth < 8
		)
		SELECT k.*, tree.depth, (k.attributes->'epoch')::bigint as epoch_n
		FROM tree JOIN knots k ON k.knot_id = tree.id
		WHERE tree.depth > 0
		ORDER BY epoch_n $direction NULLS LAST
		LIMIT ?
	");
	$sth->execute($knot_id, $limit);
	return attach_attributes $sth->fetchall_arrayref({});
};

# get_graph_json: nodes+edges for the is_parent/contains subtree under
# $knot_id (to $max_depth), plus every OTHER bound that runs between two
# knots both already in that set -- a force-directed network view (nodes
# that are also connected sideways, not just a strict tree) rather than a
# hierarchy. Pre-encoded to JSON since its only consumer is a <script> tag.
$Template::Stash::SCALAR_OPS->{get_graph_json} = sub {
	my $knot_id   = shift;
	my $max_depth = shift || 3;
	$max_depth = 5 if $max_depth > 5;

	my $tree_sth = database('knots')->prepare("
		WITH RECURSIVE tree(id, depth) AS (
			SELECT k.knot_id, 0 FROM knots k WHERE k.knot_id = ?
			UNION ALL
			SELECT b.obj, t.depth + 1
			FROM tree t
			JOIN bounds b ON b.sub = t.id AND b.predicate IN ('is_parent','contains') AND b.ord > 0
			WHERE t.depth < ?
		)
		SELECT k.knot_id, k.knot_name, tree.depth
		FROM tree JOIN knots k ON k.knot_id = tree.id
	");
	$tree_sth->execute($knot_id, $max_depth);

	my (@nodes, %seen);
	for my $row (@{ $tree_sth->fetchall_arrayref({}) }) {
		next if $seen{$row->{knot_id}}++;
		push @nodes, { id => $row->{knot_id}+0, name => _short_name($row->{knot_name}), depth => $row->{depth}+0 };
	}
	return JSON::XS->new->canonical->encode({ nodes => [], edges => [] }) unless @nodes;

	my $ids = join(',', map { $_->{id} } @nodes);
	my $edge_sth = database('knots')->prepare("
		select sub, obj, predicate from bounds
		where sub in ($ids) and obj in ($ids) and ord > 0
	");
	$edge_sth->execute();
	my @edges = map { { source => $_->{sub}+0, target => $_->{obj}+0, predicate => $_->{predicate} } }
		@{ $edge_sth->fetchall_arrayref({}) };

	return JSON::XS->new->canonical->encode({ nodes => \@nodes, edges => \@edges });
};


$Template::Stash::SCALAR_OPS->{get_graph} = sub {
	my $knot_id=shift;
	my $q="select knot_content from knots where knot_id=?"; 
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	$ref=$sth->fetchall_arrayref({});
};

$Template::Stash::SCALAR_OPS->{get_group} = sub {
	my $knot_id=shift;
	my $q="select 
		children.knot_id as knot_id,
		children.knot_name as knot_name,
		children.knot_content as knot_content,
		children.attributes as attributes
		from bounds left join knots as children on children.knot_id=bounds.obj where sub=? and predicate='is_member' and ord>0 order by ord desc,knot_id";
	 
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	$ref=$sth->fetchall_arrayref({});
	my $map_keys="";
	my $map_rels="";
	my @ids;
	for my $k (@$ref) {
		$ki=($k->{'knot_id'});
		$kn=($k->{'knot_name'});
		#$kc=($k->{'knot_content'});
		#$map_keys=$map_keys."{ \"id\": \"$kn\", \"group\": 1 },";
		$map_keys=$map_keys."\"$kn\":{\"name\":\"$kn\"},";
		push @ids,$ki;
	}
	chop $map_keys;
	my $ids=join(',',@ids);
	my $q="select predicate,source.knot_name as source,target.knot_name as target,ord as distance from bounds left join knots as source on bounds.sub=source.knot_id left join knots as target on bounds.obj=target.knot_id where obj in ($ids) and sub in ($ids) and ord>0";
	#debug $q;
	my $sth=database('knots')->prepare($q);
	$sth->execute();
	$ref=$sth->fetchall_arrayref({});
	for my $k (@$ref) {
		#$ki=($k->{'knot_id'});
		$source=($k->{'source'});
		$target=($k->{'target'});
		$distance=($k->{'distance'});
		$predicate=($k->{'predicate'});
		$map_rels=$map_rels."{ \"source\": \"$source\", \"target\": \"$target\", \"distance\": \"$distance\", \"label\":\"$predicate\"},";
		push @ids,$ki;
	}
	chop $map_rels;

	return '{"nodes":{'.$map_keys.'},"links":['.$map_rels.']}';

};	

$Template::Stash::SCALAR_OPS->{get_map} = sub {
	my $knot_id=shift;
	my $q="select 
		children.knot_id as knot_id,
		children.knot_name as knot_name,
		children.knot_content as knot_content,
		children.attributes as attributes
		from bounds left join knots as children on children.knot_id=bounds.obj where sub=? and ord>0 order by ord desc,knot_id";
	 
	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id);
	$ref=$sth->fetchall_arrayref({});
	my %concepts;
	my @terms;
	my %net;
	my $map_keys="";
	my $map_rels="";
	for my $k (@$ref) {
		$ki=($k->{'knot_id'});
		$kn=($k->{'knot_name'});
		$kc=($k->{'knot_content'});
		#$kn=~s/ /<br>/g;
		my @lok;
		my %used;
		$kc=~s/<[^>]*>//gs;
		#$kn=~s/<[^>]*>//gs;
		#push (@lok,$1) while($kn=~/[, ]([A-Z][a-z]+)/g);
		push @terms,$kn;
		$map_keys=$map_keys."{ \"id\": \"$kn\", \"group\": 1 },";
		push (@lok,$1) while($kc=~/[, ]([A-Z][a-z]+)/g);
		for  my $term (@lok) {
			if (!(exists $concepts{$term})) {
				#debug "T $term K $kn";
				$concepts{$term}=[];
			}
			push @{$concepts{$term}},$kn;
		}
		#debug "$term",@{$concepts{$term}};
	}
	for my $source (keys %concepts) {
		next if length($source)<1;
		if (@{$concepts{$source}}>1) {
			$map_keys=$map_keys."{ \"id\": \"$source\", \"group\": 1 },";
			for my $target (@{$concepts{$source}}) {	
				$map_rels=$map_rels."{ \"source\": \"$source\", \"target\": \"$target\", \"distance\": 1 },";
			}
		}
	}
	chop $map_keys;
	if (!$map_rels) {
		#debug "CREATIN PRODUCT";
		for my $source (@terms) {
			#debug "SOU $source";
			for my $target (@terms) {
				if ($source ne $target) {
					$map_rels=$map_rels."{ \"source\": \"$source\", \"target\": \"$target\", \"distance\": 1 },";
				}
			}
		}
	}

	chop $map_rels;
	return '{"nodes":['.$map_keys.'],"links":['.$map_rels.']}';

};

# Glasperlenspiel: JSON ego-network (center knot + its direct neighbours in
# either bound direction) for the interactive bead-game graph. Properly
# JSON::XS-encoded (unlike get_group/get_map above) so knot names/content
# containing quotes or backslashes can never break the payload.
$Template::Stash::SCALAR_OPS->{get_glasperlenspiel_graph} = sub {
	my $knot_id = shift;
	my $limit   = shift || 60;
	$knot_id += 0; # force numeric, this value is interpolated into SQL below

	my $nb_q = "
		select distinct n.knot_id from (
			select obj as knot_id from bounds where sub=? and ord>0
			union
			select sub as knot_id from bounds where obj=? and ord>0
			union
			select ?::int as knot_id
		) n
	";
	my $nb_sth = database('knots')->prepare($nb_q);
	$nb_sth->execute($knot_id, $knot_id, $knot_id);
	my @neighbor_ids = map { $_->{knot_id} + 0 } @{ $nb_sth->fetchall_arrayref({}) };
	@neighbor_ids = @neighbor_ids[0..$limit-1] if @neighbor_ids > $limit;
	my $ids = @neighbor_ids ? join(',', @neighbor_ids) : $knot_id;

	my $nodes_sth = database('knots')->prepare("
		select knot_id, knot_name, knot_content,
		       attributes->'img_url' as img_url,
		       attributes->'public' as is_public
		from knots where knot_id in ($ids)
	");
	$nodes_sth->execute();
	my @nodes;
	for my $row (@{ $nodes_sth->fetchall_arrayref({}) }) {
		my $content = $row->{knot_content} // '';
		$content =~ s/<[^>]+>//g;
		$content =~ s/\s+/ /g;
		$content = substr($content, 0, 220);
		push @nodes, {
			id      => $row->{knot_id} + 0,
			name    => _short_name($row->{knot_name}),
			content => $content,
			center  => ($row->{knot_id} + 0 == $knot_id) ? \1 : \0,
			img     => $row->{img_url} ? \1 : \0,
			public  => (defined $row->{is_public} && $row->{is_public} eq '1') ? \1 : \0,
		};
	}

	my $links_sth = database('knots')->prepare("
		select bound_id, sub, obj, predicate, ord
		from bounds where sub in ($ids) and obj in ($ids) and ord>0
	");
	$links_sth->execute();
	my @links;
	for my $row (@{ $links_sth->fetchall_arrayref({}) }) {
		push @links, {
			id        => $row->{bound_id} + 0,
			source    => $row->{sub} + 0,
			target    => $row->{obj} + 0,
			predicate => $row->{predicate},
			ord       => $row->{ord} + 0,
		};
	}

	return JSON::XS->new->canonical->encode({
		center => $knot_id,
		nodes  => \@nodes,
		links  => \@links,
	});
};

# Live vocabulary of the graph, queried fresh every call (cheap: a GROUP BY
# over a few thousand rows) so it never goes stale as the knowledge base grows.
$Template::Stash::SCALAR_OPS->{get_predicate_vocabulary} = sub {
	my $sth = database('knots')->prepare("select predicate, count(*) as n from bounds group by predicate order by n desc");
	$sth->execute();
	return $sth->fetchall_arrayref({});
};

$Template::Stash::SCALAR_OPS->{get_attribute_vocabulary} = sub {
	my $limit = shift || 15;
	my $sth = database('knots')->prepare("select skeys(attributes) as attr_key, count(*) as n from knots group by attr_key order by n desc limit ?");
	$sth->execute($limit);
	return $sth->fetchall_arrayref({});
};

# The labyrinth: a genuinely deep, cycle-safe descent through the taxonomy
# (is_parent + contains, mirroring the same pair get_3generations already
# treats as "descend" edges for the baumhaus/player presentation decks),
# plus -- for every knot surfaced along the way -- every OTHER (rhizomatic)
# bound it participates in. Returns plain Perl data (not JSON) for direct
# FOREACH/dot-access from TT: { tree => [...depth-ordered rows...],
# rhizome_by_node => { knot_id => [...cross-link rows...] } }.
$Template::Stash::SCALAR_OPS->{get_labyrinth} = sub {
	my $knot_id   = shift;
	my $max_depth = shift || 4;
	$max_depth = 6 if $max_depth > 6; # keep it eternal, not infinite

	my $tree_sth = database('knots')->prepare("
		WITH RECURSIVE tree(id, parent_id, depth, predicate, ord, path) AS (
			SELECT k.knot_id, NULL::int, 0, NULL::predicate, 0::numeric(10,5), ARRAY[k.knot_id]
			FROM knots k WHERE k.knot_id = ?
			UNION ALL
			SELECT b.obj, b.sub, t.depth + 1, b.predicate, b.ord::numeric(10,5), t.path || b.obj
			FROM tree t
			JOIN bounds b ON b.sub = t.id AND b.predicate IN ('is_parent','contains') AND b.ord > 0
			WHERE t.depth < ? AND NOT (b.obj = ANY(t.path))
		)
		SELECT tree.id, tree.parent_id, tree.depth, tree.predicate, tree.ord,
		       k.knot_name, k.knot_content,
		       k.attributes->'img_url' as img_url,
		       k.attributes->'ogg_url' as ogg_url,
		       k.attributes->'public'  as is_public
		FROM tree JOIN knots k ON k.knot_id = tree.id
		ORDER BY tree.path
	");
	$tree_sth->execute($knot_id, $max_depth);
	my @tree;
	for my $row (@{ $tree_sth->fetchall_arrayref({}) }) {
		my $content = $row->{knot_content} // '';
		$content =~ s/<[^>]+>//g;
		$content =~ s/\s+/ /g;
		push @tree, {
			id       => $row->{id} + 0,
			parent_id=> defined($row->{parent_id}) ? $row->{parent_id} + 0 : undef,
			depth    => $row->{depth} + 0,
			predicate=> $row->{predicate},
			name     => _short_name($row->{knot_name}),
			snippet  => substr($content, 0, 160),
			img_url  => $row->{img_url},
			ogg_url  => $row->{ogg_url},
			public   => (defined $row->{is_public} && $row->{is_public} eq '1') ? 1 : 0,
		};
	}
	return { tree => [], rhizome_by_node => {} } unless @tree;

	my $ids = join(',', map { $_->{id} } @tree);
	my $rhizome_sth = database('knots')->prepare("
		select b.bound_id, b.sub, b.obj, b.predicate, b.ord,
		       subj.knot_name as sub_name, obj.knot_name as obj_name
		from bounds b
		left join knots subj on subj.knot_id = b.sub
		left join knots obj  on obj.knot_id  = b.obj
		where (b.sub in ($ids) or b.obj in ($ids))
		  and b.predicate not in ('is_parent','contains','created_by','has_session','has_bookmark')
		  and b.ord > 0
	");
	$rhizome_sth->execute();
	my %rhizome_by_node;
	my %in_tree = map { $_->{id} => 1 } @tree;
	for my $row (@{ $rhizome_sth->fetchall_arrayref({}) }) {
		if ($in_tree{$row->{sub}+0}) {
			push @{ $rhizome_by_node{$row->{sub}+0} }, {
				dir => 'out', predicate => $row->{predicate}, ord => $row->{ord}+0,
				other_id => $row->{obj}+0, other_name => _short_name($row->{obj_name}),
			};
		}
		if ($in_tree{$row->{obj}+0}) {
			push @{ $rhizome_by_node{$row->{obj}+0} }, {
				dir => 'in', predicate => $row->{predicate}, ord => $row->{ord}+0,
				other_id => $row->{sub}+0, other_name => _short_name($row->{sub_name}),
			};
		}
	}

	# Nest the flat, depth-ordered rows into a real parent/children tree so
	# templates can render genuine <details> nesting instead of a flat,
	# indentation-only list. Boundary nodes (at exactly max_depth, i.e. the
	# deepest level actually fetched) get a `has_more` flag if they turn out
	# to have further is_parent/contains children we deliberately did not
	# fetch yet -- that flag is what a template uses to decide whether a
	# branch needs a "load more on click" placeholder.
	my %node_by_id = map { $_->{id} => { %$_, children => [] } } @tree;
	for my $n (@tree) {
		next unless defined $n->{parent_id};
		push @{ $node_by_id{$n->{parent_id}}{children} }, $node_by_id{$n->{id}}
			if $node_by_id{$n->{parent_id}};
	}
	# Within each level, group by the predicate that attaches the child to
	# its parent: is_parent first, then contains. sort() is stable (since
	# Perl 5.8), so the original path-based order survives within each group.
	my %predicate_rank = (is_parent => 0, contains => 1);
	for my $node (values %node_by_id) {
		$node->{children} = [ sort {
			($predicate_rank{$a->{predicate}} // 2) <=> ($predicate_rank{$b->{predicate}} // 2)
		} @{ $node->{children} } ];
	}
	my ($root_row) = grep { $_->{depth} == 0 } @tree;
	my $root = $node_by_id{$root_row->{id}};

	my @boundary_ids = map { $_->{id} } grep { $_->{depth} == $max_depth } @tree;
	if (@boundary_ids) {
		my $bids = join(',', @boundary_ids);
		my $more_sth = database('knots')->prepare("
			select distinct sub from bounds
			where sub in ($bids) and predicate in ('is_parent','contains') and ord > 0
		");
		$more_sth->execute();
		my %has_more = map { $_->{sub} => 1 } @{ $more_sth->fetchall_arrayref({}) };
		for my $id (@boundary_ids) {
			$node_by_id{$id}{has_more} = $has_more{$id} ? 1 : 0;
		}
	}

	return { tree => \@tree, root => $root, rhizome_by_node => \%rhizome_by_node };
};

# JSON-encoded variant of get_labyrinth, for lazy on-click expansion: a branch
# fetches its own next couple of levels via this, instead of the whole
# labyrinth being fetched and rendered eagerly on first paint.
$Template::Stash::SCALAR_OPS->{get_labyrinth_json} = sub {
	my $knot_id   = shift;
	my $max_depth = shift || 2;
	my $data = $Template::Stash::SCALAR_OPS->{get_labyrinth}->($knot_id, $max_depth);
	return JSON::XS->new->canonical->encode($data);
};

$Template::Stash::SCALAR_OPS->{get_2generations_map} = sub {
	my $knot_id=shift;
	my $q="
		(select
		children.ord,children.knot_id as parent_id, '2' as depth,
		bounds.ord as ord2,
		children.knot_name as parent_name,
		grandchildren.knot_id as knot_id,
		grandchildren.knot_name as knot_name,
		grandchildren.knot_content as knot_content,
		grandchildren.attributes as attributes
 from (select children.*,bounds.* from bounds left join knots as children on children.knot_id=bounds.obj where sub=? and predicate='is_parent' order by ord desc,knot_id) children left join bounds on bounds.sub=children.knot_id left join knots as grandchildren on bounds.obj=grandchildren.knot_id where ";
	$q.=" bounds.ord>0 order by bounds.ord desc,children.ord desc,children.knot_id asc)
		UNION (
		select ord,children.knot_id as parent_id, '1' as depth,
		1 as ord2,
		'' as parent_name,
		children.knot_id as knot_id,
		children.knot_name as knot_name,
		children.knot_content as knot_content,
		children.attributes as attributes
		from bounds left join knots as children on children.knot_id=bounds.obj where sub=? and ord>0 order by ord desc,knot_id 
		) 
		order by ord desc,parent_id,depth,ord2 desc
";

	my $sth=database('knots')->prepare($q);
	$sth->execute($knot_id,$knot_id);
	$ref=$sth->fetchall_arrayref({});
	my %concepts;
	my %net;
	for my $k (@$ref) {
		$ki=($k->{'knot_id'});
		$kn=($k->{'knot_name'});
		$kc=($k->{'knot_content'});
		my @lok;
		my %used;
		$kc=~s/<[^>]*>//gs;
		$kn=~s/<[^>]*>//gs;
		push (@lok,$1) while($kn=~/[, ]([A-Z][a-z]+)/g);
		push (@lok,$1) while($kc=~/[, ]([A-Z][a-z]+)/g);
		#$map=$map."$kn,@lok\n";
		for $l1 (@lok) {
			next if exists $used{$l1};	
			next if length $l1 < 4;
			if (exists $concepts{$l1}) {
				$concepts{$l1}=$concepts{$l1}+1;
			} else {
				$concepts{$l1}=1;
			}
			for $l2 (@lok) {
				#next if exists $used{$l2};	
				next if length $l2 < 4;
				if (!exists $net{$l1}{$l2}) {
					$net{$l1}{$l2}=1;
				} else {
					$net{$l1}{$l2}=$net{$l1}{$l2}+1;
				}
			}
			#$used{$l1}=1;
		}
	}
	for my $k (%concepts) {
		if ($concepts{$k}>1) {
			$map_keys=$map_keys."{ \"id\": \"$k\", \"group\": $concepts{$k} },";
		}
	}
	for $k1 (keys %net) {
		for $k2 (keys @{$net{$k1}}) {
			if ($net{$k1}{$k2} && ($k1 ne $k2) && $concepts{$k1}>1 && $concepts{$k2} >1) {
				$map_rels=$map_rels."{ \"source\": \"$k1\", \"target\": \"$k2\", \"distance\": $net{$k1}{$k2} },";
			}
		}
	}
	chop $map_keys;
	chop $map_rels;
	my $json= '{"nodes":['.$map_keys.'],"links":['.$map_rels.']}';
	return $json;
};

