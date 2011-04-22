package RebuildTrigger::L10N::ja;
use strict;
use base 'RebuildTrigger::L10N';
use vars qw( %Lexicon );

our %Lexicon = (
    'Add rebuild trigger.' => '再構築トリガーを追加します。',
    'Trigger' => '再構築トリガー',
    'You can write YAML format. Example:' => 'YAML形式で指定します。例:',
    'To use this, You specify the RebuildTriggerPluginSetting 1 in mt-config.cgi.' => 'プラグイン設定で再構築トリガーを指定するには mt-config.cgi に RebuildTriggerPluginSetting 1 を指定してください。',
);

1;