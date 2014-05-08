package RebuildTrigger::Plugin;

use strict;

sub _post_run {
    my $app = MT->instance();
    return 1 if ( ( ref $app ) ne 'MT::App::CMS' );
    return 1 if (! MT->config( 'RebuildTriggerPluginSetting' ) );
    my $query_string = $app->query_string;
    return 1 unless $query_string;
    require MT::Request;
    my $r = MT::Request->instance;
    return 1 if $r->cache( 'RebuildTriggerDoPlugin' );
    $r->cache( 'RebuildTriggerDoPlugin', 1 );
    my $component = MT->component( 'RebuildTrigger' );
    my $config = $component->get_config_value( 'rebuildtrigger' );
    return 1 unless $config;
    $config .= "\n";
    require YAML::Tiny;
    my $tiny = YAML::Tiny->new;
    $tiny = YAML::Tiny->read_string( $config ) || YAML::Tiny->errstr;
    if ( ref $tiny ne 'YAML::Tiny' ) {
        $app->log( $component->translate( 'YAML Error \'[_1]\'', $tiny ) );
    }
    my $yaml = $tiny->[ 0 ];
    my @query_params = split( /;/, $query_string );
    my @template_ids;
    my @blog_ids;
    my @archive_types;
    for my $key ( keys %$yaml ) {
        my $params = $yaml->{ $key }->{ params };
        my $template_id = $yaml->{ $key }->{ template_id };
        my $blog_id = $yaml->{ $key }->{ blog_id };
        next if ( (! $template_id ) && (! $blog_id ) );
        next if (! $params );
        my $rebuild = 1;
        if ( ( ref $params ) eq 'ARRAY' ) {
            for my $param ( @$params ) {
                if (! grep( /^$param$/, @query_params ) ) {
                    $rebuild = 0;
                    next;
                }
            }
        } else {
            if ( $query_string eq $params ) {
                $rebuild = 1;
            }
        }
        if ( $rebuild ) {
            if ( $blog_id ) {
                if ( ( ref $blog_id ) eq 'ARRAY' ) {
                    for my $id ( @$blog_id ) {
                        push ( @blog_ids, $id );
                    }
                } else {
                    push ( @blog_ids, $blog_id );
                }
                my $archive_type = $yaml->{ $key }->{ archive_type };
                if ( $archive_type ) {
                    if ( ( ref $archive_type ) eq 'ARRAY' ) {
                        for my $type ( @$archive_type ) {
                            push ( @archive_types, $type );
                        }
                    } else {
                        push ( @archive_types, $archive_type );
                    }
                }
            } elsif ( $template_id ) {
                if ( ( ref $template_id ) eq 'ARRAY' ) {
                    for my $id ( @$template_id ) {
                        push ( @template_ids, $id );
                    }
                } else {
                    push ( @template_ids, $template_id );
                }
            }
        }
    }
    if ( @blog_ids ) {
        require MT::Template::Tags::Filters;
        require MT::Template;
        require MT::Builder;
        require MT::Template::Context;
        my $ctx = MT::Template::Context->new;
        my $builder = MT::Builder->new;
        $ctx->stash( 'builder', $builder );
        if ( my $blog = $app->blog ) {
            $ctx->stash( 'blog', $blog );
        }
        my @build_ids;
        for my $id ( @blog_ids ) {
            if ( $id =~ /mt/i ) {
                $id = MT::Template::Tags::Filters::_fltr_mteval( $id, 1, $ctx );
            }
            push ( @build_ids, $id );
        }
        __rebuild_blogs( \@build_ids, \@archive_types );
    }
    if ( @template_ids ) {
        __rebuild_templates( @template_ids );
    }
    return 1;
}

sub _cms_post_delete_entry {
    my ( $cb, $app, $obj ) = @_;
    return 1 if (! MT->config( 'RebuildMultiBlogAtDeleteEntry' ) );
    require MT::Request;
    my $r = MT::Request->instance;
    my $plugin = MT->component( 'MultiBlog' );
    return unless $plugin;
    return 1 if $r->cache( 'rebuildtrigger-multiblog:' . $obj->blog_id );
    $r->cache( 'rebuildtrigger-multiblog:' . $obj->blog_id, 1 );
    force_background_task( sub
                { require MultiBlog; MultiBlog::post_entry_save( $plugin, $cb, $app, $obj ); } );
    return 1;
}

sub _hdlr_rebuild {
    my ( $ctx, $args, $cond ) = @_;
    my $url = $args->{ url };
    my $blog_id = $args->{ blog_id };
    my $blog = $ctx->stash( 'blog' );
    if ( $blog_id ) {
        require MT::Blog;
        $blog = MT::Blog->load( $blog_id );
        $ctx->stash( 'blog', $blog );
        $ctx->stash( 'blog_id', $blog_id );
    }
    my $app = MT->instance;
    if (! $blog ) {
        if ( ref( $app ) =~ /^MT::App::/ ) {
            $blog = $app->blog;
        }
        if (! $blog ) {
            return $ctx->error( MT->translate( 'No [_1] could be found.', 'Blog' ) );
        }
    }
    $blog_id = $blog->id;
    if ( $url ) {
        my $blog_url = $blog->site_url;
        $blog_url =~ s!/$!!;
        if ( $url =~ m!^https{0,1}://! ) {
            $blog_url =~ s!(^https{0,1}://.*?)/.*$!$1!;
            my $search = quotemeta( $blog_url );
            $url =~ s/^$search//;
            require MT::FileInfo;
            my $fi = MT::FileInfo->load( { blog_id => $blog_id,
                                           url => $url } );
            if (! $fi ) {
                return '';
            }
            require MT::WeblogPublisher;
            my $pub = MT::WeblogPublisher->new;
            $pub->rebuild_from_fileinfo( $fi ) || die $pub->errstr;
        }
    }
    my $template_id = $args->{ template_id };
    my $archive_type = $args->{ archive_type };
    my @template_ids;
    my @blog_ids;
    my @archive_types;
    if ( $args->{ template_ids } ) {
        @template_ids = split( /,/, $args->{ template_ids } );
    } else {
        push ( @template_ids, $template_id ) if $template_id;
    }
    if ( $args->{ blog_ids } ) {
        @blog_ids = split( /,/, $args->{ blog_ids } );
    } else {
        push ( @blog_ids, $blog_id );
    }
    if ( $args->{ archive_types } ) {
        @archive_types = split( /,/, $args->{ archive_types } );
    } else {
        push ( @archive_types, $archive_type );
    }
    if ( @blog_ids ) {
        my @build_ids;
        for my $id ( @blog_ids ) {
            push ( @build_ids, $id );
        }
        __rebuild_blogs( \@build_ids, \@archive_types );
    }
    if ( @template_ids ) {
        __rebuild_templates( @template_ids );
    }
    if ( my $need_result = $args->{ need_result } ) {
        return 1;
    }
    return '';
}

sub _hdlr_rebuild_blog {
    my ( $ctx, $args, $cond ) = @_;
    my $app = MT->instance;
    if ( ref ( $app ) eq 'MT::App::CMS' ) {
        my $mode = $app->mode;
        if ( $mode && ( $mode =~ /preview/ ) ) {
            return;
        }
    }
    my $blog_id = $args->{ blog_id };
    $blog_id = $args->{ id } if (! $blog_id );
    $blog_id = $args->{ blog_ids } if (! $blog_id );
    my $archivetype = $args->{ ArchiveType };
    $archivetype = $args->{ archivetype } if (! $archivetype );
    $archivetype = $args->{ archive_type } if (! $archivetype );
    $archivetype = '' if (! $archivetype );
    my @ats;
    if ( $archivetype ) {
        @ats = split( /\,/, $archivetype );
        @ats = map { $_ =~ s/\s//g; $_; } @ats;
    }
    require MT::Request;
    my $r = MT::Request->instance;
    my @blog_ids = split( /\,/, $blog_id );
    @blog_ids = map { $_ =~ s/\s//g; $_; } @blog_ids;
    return '' unless @blog_ids;
    return __rebuild_blogs( \@blog_ids, \@ats );
    return '';
}

sub _hdlr_rebuild_indexbyid {
    my ( $ctx, $args, $cond ) = @_;
    my $app = MT->instance;
    if ( ref ( $app ) eq 'MT::App::CMS' ) {
        my $mode = $app->mode;
        if ( $mode && ( $mode =~ /preview/ ) ) {
            return;
        }
    }
    my $template_id = $args->{ template_id };
    $template_id = $args->{ id } if (! $template_id );
    $template_id = $args->{ template_ids } if (! $template_id );
    return '' unless $template_id;
    require MT::Request;
    my $r = MT::Request->instance;
    my @template_ids = split( /\,/, $template_id );
    @template_ids = map { $_ =~ s/\s//g; $_; } @template_ids;
    __rebuild_templates( @template_ids );
    return '';
}

sub _hdlr_if_setting {
    my ( $ctx, $args, $cond ) = @_;
    return 1 if ( MT->config( 'RebuildTriggerPluginSetting' ) );
    return 0;
}

sub _hdlr_rebuild_indexbyblogid {
    my ( $ctx, $args, $cond ) = @_;
    $args->{ ArchiveType } = 'Index';
    return _hdlr_rebuild_blog( $ctx, $args, $cond );
}

sub __rebuild_templates {
    my $app = MT->instance;
    if ( ref ( $app ) eq 'MT::App::CMS' ) {
        my $mode = $app->mode;
        if ( $mode && ( $mode =~ /preview/ ) ) {
            return;
        }
    }
    my @template_ids = @_;
    require MT::Request;
    my $r = MT::Request->instance;
    require MT::Template;
    my @templates = MT::Template->load( { id => \@template_ids } );
    return '' unless @templates;
    require MT::WeblogPublisher;
    my $pub = MT::WeblogPublisher->new;
    for my $template ( @templates ) {
        next if ( $r->cache( 'rebuildtrigger-rebuild-template_id:' . $template->id ) );
        if ( my $blog_id = $template->blog_id ) {
            force_background_task( sub
                { $pub->rebuild_indexes( BlogID => $blog_id, Template => $template, Force => 1, ); } );
        }
        $r->cache( 'rebuildtrigger-rebuild-template_id:' . $template->id, 1 );
    }
}

sub __rebuild_blogs {
    my ( $blog_ids, $ats ) = @_;
    require MT::Request;
    my $r = MT::Request->instance;
    require MT::WeblogPublisher;
    my $pub = MT::WeblogPublisher->new;
    for my $id ( @$blog_ids ) {
        if ( @$ats ) {
            for my $archive_type ( @$ats ) {
                next if ( $r->cache( 'rebuildtrigger-rebuild-blog_id:' . $id . ':' . $archive_type ) );
                if ( $archive_type ne 'index' ) {
                    force_background_task( sub
                        { $pub->rebuild( BlogID => $id, ArchiveType => $archive_type, NoIndexes => 1 ); } );
                } else {
                    force_background_task( sub
                        { $pub->rebuild_indexes( BlogID => $id, Force => 1, ); } );
                }
                $r->cache( 'rebuildtrigger-rebuild-blog_id:' . $id . ':' . $archive_type, 1 );
            }
        } else {
            next if ( $r->cache( 'rebuildtrigger-rebuild-blog_id:' . $id ) );
            force_background_task( sub
                    { $pub->rebuild( BlogID => $id ); } );
            $r->cache( 'rebuildtrigger-rebuild-blog_id:' . $id, 1 );
        }
    }
    return '';
}

sub force_background_task {
    my $app = MT->instance();
    my $fource = $app->config->RebuildTriggerBackgroundTasks;
    if ( ( $fource ) && (! $ENV{ FAST_CGI } ) ) {
        my $default = $app->config->LaunchBackgroundTasks;
        $app->config( 'LaunchBackgroundTasks', 1 );
        my $res = MT::Util::start_background_task( @_ );
        $app->config( 'LaunchBackgroundTasks', $default );
        return $res;
    }
    return MT::Util::start_background_task( @_ );
}

1;