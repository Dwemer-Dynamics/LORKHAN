local M={}
local PAGE_SIZE=10

-- Keep server settings in short pages and a single focused editor, like the other Interact menus.
function M.build(context)
    local ui,util=context.ui,context.util
    local rows={}
    local function row(label,callback,quiet)
        rows[#rows+1]={type=ui.TYPE.Text,props={text=label,textSize=17,
            textColor=quiet and util.color.rgb(0.75,0.72,0.66) or util.color.rgb(188/255,157/255,90/255)},
            events=callback and {mouseClick=context.wrap(callback)} or nil}
    end
    row('Settings',nil,true)
    if not context.editor then
        row('Settings are not loaded. Refresh to try again.',nil,true)
    elseif context.field then
        local field=context.field
        row(field.label,nil,true)
        if field.kind=='choice' then
            local choices=field.choices or {}
            local page=math.min(context.page,math.max(1,math.ceil(#choices/PAGE_SIZE)))
            for index=(page-1)*PAGE_SIZE+1,math.min(page*PAGE_SIZE,#choices) do
                local choice=choices[index]
                row(choice.label..(choice.value==field.value and ' [active]' or ''),function() context.save(choice.value) end)
            end
            if page>1 then row('Previous',function() context.setPage(page-1) end) end
            if page*PAGE_SIZE<#choices then row('Next',function() context.setPage(page+1) end) end
        else
            local editorValue=context.value or ''
            rows[#rows+1]={type=ui.TYPE.TextEdit,props={text=context.value or '',textSize=17,
                size=util.vector2(590,field.kind=='string' and 120 or 40),multiline=field.kind=='string',
                wordWrap=true,readOnly=context.pending,autoSize=false},events={textChanged=context.wrap(function(value)
                    editorValue=type(value)=='string' and value or ''
                    context.changeValue(editorValue)
                end)}}
            if field.kind=='integer' then row('Range: '..tostring(field.minimum or '-')..' to '..tostring(field.maximum or '-'),nil,true) end
            row('Save',function() context.save(editorValue) end)
        end
        row('Cancel',context.cancel)
    elseif context.scope then
        local section
        for _,candidate in ipairs(context.editor.sections) do if candidate.scope==context.scope then section=candidate end end
        if section then
            row(section.label,nil,true)
            local page=math.min(context.page,math.max(1,math.ceil(#section.fields/PAGE_SIZE)))
            for index=(page-1)*PAGE_SIZE+1,math.min(page*PAGE_SIZE,#section.fields) do
                local field=section.fields[index]
                local value=field.value
                if field.kind=='boolean' then value=value=='true' and 'On' or 'Off' end
                for _,choice in ipairs(field.choices or {}) do if choice.value==field.value then value=choice.label end end
                value=value:gsub('%s+',' ')
                if #value>36 then value=value:sub(1,33)..'...' end
                row(field.label..': '..value,function() context.edit(field) end)
            end
            row('Page '..page..' / '..math.max(1,math.ceil(#section.fields/PAGE_SIZE)),nil,true)
            if page>1 then row('Previous',function() context.setPage(page-1) end) end
            if page*PAGE_SIZE<#section.fields then row('Next',function() context.setPage(page+1) end) end
        end
        row('Back to Settings',context.backToHub)
    else
        for _,section in ipairs(context.editor.sections) do
            row(section.label,function() context.openSection(section.scope) end)
        end
        row('LLM model...',context.models)
        row('Dynamic profiles...',context.profiles)
        row('Read books aloud: '..(context.readBooks and 'On' or 'Off'),context.toggleBooks)
    end
    if context.pending then row('Saving / loading...',nil,true) end
    if not context.field then row('Refresh',context.refresh) end
    row('Back to Interact',context.back)
    return rows
end

return M
