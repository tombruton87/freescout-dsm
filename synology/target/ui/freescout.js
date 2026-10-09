// FreeScout's window in DSM. DSM loads this from ui/config when FreeScout is
// opened from its main menu; the window shows panel.html, beside this, which
// DSM serves — so it's on DSM's own address, behind DSM's sign-in.
Ext.ns("FreeScout");

Ext.define("FreeScout.AppInstance", {
    extend: "SYNO.SDS.AppInstance",
    appWindowName: "FreeScout.AppWindow"
});

Ext.define("FreeScout.AppWindow", {
    extend: "SYNO.SDS.AppWindow",
    constructor: function (config) {
        this.callParent([Ext.apply({
            title: "FreeScout",
            width: 960,
            height: 680,
            minWidth: 520,
            minHeight: 380,
            resizable: true,
            maximizable: true,
            minimizable: true,
            layout: "fit",
            items: [{
                xtype: "box",
                autoEl: {
                    tag: "iframe",
                    src: "/webman/3rdparty/freescout/panel.html",
                    frameborder: 0,
                    style: "width:100%;height:100%;border:0;display:block"
                }
            }]
        }, config)]);
    }
});
