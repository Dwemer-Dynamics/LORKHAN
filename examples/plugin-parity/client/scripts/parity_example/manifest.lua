-- Lua copy of server/lorkhan-plugin.json. LORKHAN's Lua test proves the canonical JSON encoding of this table equals
-- those packaged bytes; sha256 is SHA-256 of the same bytes and is checked by the server against its installed copy.
return {
    sha256='4a44b0af71ffdda44c3a7f68fd70d340b4a0e8fa142b16fdfd2d107ef62e20b0',
    manifest={
        schema='lorkhan.plugin.manifest.v1',plugin_id='parity.example',version='1.0.0',api_version=1,
        display_name='Parity Example',
        description='Minimal LORKHAN_Addons v1 example with one GLOBAL and one SELF action.',
        author='Dwemer Dynamics',default_enabled=false,
        compatibility={product='lorkhan',game='tes3',min_client_version='0.5.0',min_server_version='0.5.0',lua_api_revision=129},
        dependencies={},
        actions={
            {name='mark_camp',display_name='Mark camp',description='Record the camp mood an actor reports.',
                tier=0,confirmation='none',executor_kinds={'npc','creature'},target='none',target_kinds={},
                timeout_seconds=30,cancellable=true,
                parameters={{name='mood',type='enum',required=true,values={'calm','alert'}}}},
            {name='wander_briefly',display_name='Wander briefly',description='The actor wanders near its current spot.',
                tier=2,confirmation='required',executor_kinds={'npc'},target='none',target_kinds={},
                timeout_seconds=20,cancellable=true,
                parameters={{name='distance',type='integer',required=true,minimum=64,maximum=512}}},
        },
        events={
            {name='camp_marked',description='An actor marked the camp mood.',max_per_minute=6,
                fields={{name='actor',type='actor',required=true,actor_kinds={'npc','creature'}},
                    {name='mood',type='text',required=true,max_length=16}}},
        },
        prompt_contributions={},
    },
}
