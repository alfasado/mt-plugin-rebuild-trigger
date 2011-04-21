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
    require YAML::Tiny;
    my $tiny = YAML::Tiny->new;
    $tiny = YAML::Tiny->read_string( $config ) || die YAML::Tiny->errstr;
    if ( ref $tiny ne 'YAML::Tiny' ) {
        $app->log( $component->translate( 'YAML Error \'[_1]\'', $tiny ) );
    }
    my $yaml = $tiny->[ 0 ];
    my @query_params = split( /;/, $query_string );
    my @template_ids;
    my $counter = 1;
    for my $key ( keys %$yaml ) {
        my $params = $yaml->{ $key }->{ params };
        my $template_id = $yaml->{ $key }->{ template_id };
        next if (! $template_id );
        next if (! $params );
        $counter++;
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
            push ( @template_ids, $template_id );
        }
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
                { MultiBlog::post_entry_save( $plugin, @_ ); } );
    return 1;
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
    require MT::WeblogPublisher;
    my $pub = MT::WeblogPublisher->new;
    for my $id ( @blog_ids ) {
        if ( @ats ) {
            for my $archive_type ( @ats ) {
                next if ( $r->cache( 'rebuildtrigger-rebuild-blog_id:' . $id . ':' . $archive_type ) );
                force_background_task( sub
                    { $pub->rebuild( BlogID => $id, ArchiveType => $archive_type ); } );
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
    $template_id = $args->{ template_ids } if (! $template_id );
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

sub force_background_task {
    my $app = MT->instance();
    my $fource = $app->config->FourceBackgroundTasks;
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