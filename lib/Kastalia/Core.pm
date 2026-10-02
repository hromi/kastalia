sub attach_attributes {
	my $aref=shift;
	for my $item (@$aref) {
		my $attributes = Pg::hstore::decode($item->{attributes});
		for my $a_k (keys %$attributes) {
			if ($a_k eq 'epoch') {
				my @t=localtime($attributes->{$a_k});
				#debug "TIME $item->{$a_k} @t";
				my $year=$t[5]-70;
				my $suffix=strftime('%m%d',@t);
				$item->{'ae_epoch'}='AE'.$year.$suffix;
				$item->{'date'}=strftime('%d.%m.%Y',@t);
			}
			#else {
			if ($a_k !~/^knot_/ and $attributes->{$a_k}) {
				$item->{$a_k}=$attributes->{$a_k};
			}
			#debug "ATTACHIN $a_k".$item->{$a_k};
		}
	}
	#debug $aref;
	return $aref;
}

sub upsertBound {
	(my $sub, my $predicate, my $obj, my $init_weight, my $operation, my $parameter, my $msg) = @_;
	debug("MSG$msg");
	#database('knots')->trace(2);
	#$ord=1 if (!$ord);
	my $q="insert into bounds (sub,predicate,obj,ord,bound_creator) values (?,?,?,((select ord from bounds as b where sub=? and predicate=? and obj=?) union (select ?) limit 1),?) on conflict(sub, obj, predicate, ord) do update set ord=excluded.ord $operation ? returning bound_id,ord";
	my $user_id=session('user_id');
	#debug("UPSERT $sub,$predicate,$obj,$sub,$predicate,$obj,$init_weight,$user_id,$parameter,$msg");
	my $sth=database('knots')->prepare($q);
	#debug($q);
	#database('knots')->trace(2);
	$sth->execute($sub,$predicate,$obj,$sub,$predicate,$obj,$init_weight,$user_id,$parameter);
	$result = $sth->fetchrow_hashref;
	my $bound_id=$result->{'bound_id'};
	my $ord=$result->{'ord'};
	#debug("UPSERTED $bound_id to $ord");
	addZeitgeist(session('user_id'),'upsert_bound','TEST',{obj=>$obj, sub=>$sub, predicate=>$predicate,ord=>$ord,bound_id=>$bound_id,bound_creator=>$user_id,msg=>$msg,operation=>"$operation $parameter"});
}


sub addBound {
	(my $sub, my $predicate, my $obj, my $ord) = @_;
	$ord=1 if (!$ord);
	my $sth=database('knots')->prepare('INSERT INTO bounds(sub,predicate,obj,ord, bound_creator) VALUES (?,?,?,?,?)');						
	debug "ADDBOUND $sub $predicate $obj $ord".session('user_id');
	$sth->execute($sub,$predicate,$obj,$ord,session('user_id'));
	my $bound_id = database('knots')->last_insert_id(undef,undef,undef,undef,{sequence=>'bound_id_seq'});
	addZeitgeist(session('user_id'),'add_bound','post',{obj=>$obj, sub=>$sub, predicate=>$predicate,ord=>$ord,bound_id=>$bound_id});
}

sub strenghtenBound {
	my $knot_id=shift;
	my $role=shift;
	$role='sub' if !$role;
	my $predicate=shift;
	my $sth=database('knots')->prepare("update bounds set ord=ord+1 where $role=? and predicate=?");	
	$sth->execute($knot_id,$predicate);
}

sub resetBound {
	my $knot_id=shift;
	my $role=shift;
	$role='sub' if !$role;
	my $predicate=shift;
	my $sth=database('knots')->prepare("update bounds set ord=0 where $role=? and predicate=?");	
	$sth->execute($knot_id,$predicate);
}



sub addZeitgeist {
	(my $agent, my $action, my $method, my $vars) = (@_);
	my $sth=database('knots')->prepare('insert into zeitgeist values (NOW(),?,?,?,?)');
	$vars->{'login'}=session('login') if session('login');
	$sth->execute($agent,$action,$method,Pg::hstore::encode($vars));
}


sub addKnot {
	(my $knot_name, my $knot_content, my $attributes) = (@_);
	if ((session('login'))) {
		$attributes->{'creator'}=(session('login'));
	}
	if ($attributes) {
		my $sth=database('knots')->prepare('insert into knots (knot_name,knot_content,attributes) values (?,?,?)');
		$sth->execute($knot_name, $knot_content, Pg::hstore::encode($attributes));
	} else {
		my $sth=database('knots')->prepare('insert into knots (knot_name,knot_content) values (?,?)');
		$sth->execute($knot_name, $knot_content);
	
	}
	my $knot_id = database('knots')->last_insert_id(undef,undef,undef,undef,{sequence=>'knots_knot_id_seq'});
	addAttribute($knot_id,'epoch',time);
	addBound((session('user_id')),'created_by',$knot_id) if (session('user_id'));
	return $knot_id;
}

sub addAttribute {
	(my $knot_id, my $a_name, my $a_value) = (@_);
	my $sth2 = database('knots')->prepare("update knots set attributes=attributes || ? where knot_id=?");
	$sth2->execute(hstore_encode({$a_name=>$a_value}),$knot_id);
}

# knotize_node: turn one node of a decoded JSON tree (a hashref, as produced
# e.g. by an AI system asked to draft a presentation) into a knot, bound to
# $parent_id (if any) with predicate 'is_parent' by default -- the same shape
# /insert/ and /split/ already build, and the one get_2generations/
# get_3generations (and thus baumhaus/player) expect when walking a deck.
#
# Recognized keys on a node:
#   name | knot_name | title   -> knot_name
#   content | knot_content     -> knot_content
#   attributes                 -> hashref, merged into the knot's hstore
#   predicate                  -> predicate of the bound to its parent (default 'is_parent')
#   ord                        -> ord of the bound to its parent (default: $ord, or 1)
#   slides | children          -> arrayref of child nodes, knotized recursively
#                                  underneath the knot just created
#
# knot_name doubles as this knot's materialized path elsewhere in the graph
# (see TT.pm's get_materialized_paths and its use in arbre.tt to build a
# dynamic knot_name tree via a "starts with" match) -- so the leaf name given
# in the node is prefixed with its parent's own knot_name/path, "/"-joined,
# the same convention /split/ already uses. $parent_path is the parent's
# already-expanded path, threaded through the recursion; when it's not given
# (the top-level call) it's looked up from $parent_id, if any.
#
# At the top-level call (parent_path not yet known), if the node's own name
# is exactly $parent_id's leaf name, the caller is almost certainly re-posting
# a JSON export of $parent_id itself (or AI-authored JSON that re-titled the
# root after the knot it's meant to land in) -- creating a redundant
# same-named child here would otherwise double up that path segment on every
# descendant (knotize this into knot 2709 "...420/Memes in Alltag" with a
# JSON root {"name":"Memes in Alltag", slides:[...]} and you'd get a child
# 2723 ".../Memes in Alltag/Memes in Alltag" holding the real deck instead of
# 2709 itself). In that case $parent_id is treated AS this node: its
# knot_content/attributes are merged onto the existing knot instead of
# spawning a new one, and the children knotize directly underneath it.
#
# Returns the knot_id this node ended up as (a fresh one, or $parent_id).
sub knotize_node {
	(my $node, my $parent_id, my $ord, my $parent_path) = @_;
	return undef unless ref($node) eq 'HASH';

	my $knot_name    = $node->{'name'} // $node->{'knot_name'} // $node->{'title'} // '';
	my $knot_content = $node->{'content'} // $node->{'knot_content'} // '';
	my $attributes   = (ref($node->{'attributes'}) eq 'HASH') ? $node->{'attributes'} : {};

	my $target;
	if (!defined $parent_path && $parent_id) {
		$target = get_knot($parent_id);
		$parent_path = $target->{'knot_name'} if $target;
	}

	if ($target && $knot_name ne '' && _short_name($target->{'knot_name'}) eq $knot_name) {
		if ($knot_content ne '') {
			my $sth = database('knots')->prepare('update knots set knot_content = ? where knot_id = ?');
			$sth->execute($knot_content, $parent_id);
		}
		addAttribute($parent_id, $_, $attributes->{$_}) for keys %$attributes;

		my $children = $node->{'slides'} || $node->{'children'};
		if (ref($children) eq 'ARRAY') {
			my $i = 0;
			for my $child (@$children) {
				$i++;
				knotize_node($child, $parent_id, $i*10, $parent_path);
			}
		}
		return $parent_id;
	}

	my $full_name = (defined $parent_path && $parent_path ne '')
		? ($knot_name ne '' ? "$parent_path/$knot_name" : $parent_path)
		: $knot_name;

	my $knot_id = addKnot($full_name, $knot_content, $attributes);

	if ($parent_id) {
		my $predicate  = $node->{'predicate'} || 'is_parent';
		my $bound_ord  = $node->{'ord'} // $ord // 1;
		addBound($parent_id, $predicate, $knot_id, $bound_ord);
	}

	my $children = $node->{'slides'} || $node->{'children'};
	if (ref($children) eq 'ARRAY') {
		my $i = 0;
		for my $child (@$children) {
			$i++;
			knotize_node($child, $knot_id, $i*10, $full_name);
		}
	}
	return $knot_id;
}

# knotize_list: same as knotize_node, but for a bare arrayref of sibling
# nodes with no synthetic wrapper knot -- e.g. "inject these slides directly
# under an already existing presentation knot". $parent_id is required.
# The parent's knot_name/path is looked up once and threaded through every
# child, same materialized-path expansion as knotize_node.
# Returns an arrayref of the created knot_ids, in JSON order.
sub knotize_list {
	(my $list, my $parent_id) = @_;
	return [] unless ref($list) eq 'ARRAY';
	my $parent = get_knot($parent_id);
	my $parent_path = $parent ? $parent->{'knot_name'} : undef;
	my @ids;
	my $i = 0;
	for my $node (@$list) {
		$i++;
		push @ids, knotize_node($node, $parent_id, $i*10, $parent_path);
	}
	return \@ids;
}

sub login {
	($login,$ajax)=shift;
	debug("LOGIN IN ".$login);
	session 'user'=>$login;
	my $user_knot=get_first_knot_with_name($login);
	if ($user_knot->{knot_id}) {
		session 'user_id' => $user_knot->{knot_id};
		#server-side variables ... 
		for my $k ('zodiac','consent','gender','age','motherlang','voice','home_knot','collects','font','score','text_transform') {
			#debug "$k $user_knot->{$k}";
			session $k => $user_knot->{$k};
		}
	} else {
		session 'user_id' => addKnot($l,"Profile of $l\n");	
	}
	my $dispatch = session 'dispatch';
	my $home_knot = session 'home_knot';
	#debug "Logging in $l with ID ".$user_knot->{knot_id};
	session 'bookmarks' => get_bookmarks($user_knot->{knot_id});
	#my $shortlogin=$l;
	session 'login' => $login;
	$dispatch = params->{force_dispatch} if params->{force_dispatch};
	if ($home_knot) {
		debug "HK".$home_knot;
		$ajax ? return $home_knot : forward  "/".$home_knot ,{err=>''},{method=>'GET'};
	}
	elsif ($dispatch) {
		debug "DISPATCH ".$dispatch;
		forward  $dispatch ,{err=>''},{method=>'GET'};
	} else {
		forward  "/last/" ,{},{method=>'GET'};
	}
}

true;
