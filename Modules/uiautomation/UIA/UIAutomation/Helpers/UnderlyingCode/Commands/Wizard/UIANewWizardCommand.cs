/*
 * Created by SharpDevelop.
 * User: Alexander Petrovskiy
 * Date: 3/15/2013
 * Time: 12:09 AM
 * 
 * To change this template use Tools | Options | Coding | Edit Standard Headers.
 */

namespace UIAutomation
{
    using System;
    using System.Management.Automation;
    using UIAutomation.Commands;
    
    /// <summary>
    /// Description of UIANewWizardCommand.
    /// </summary>
    internal class UIANewWizardCommand : UIACommand
    {
        internal UIANewWizardCommand(CommonCmdletBase cmdlet) : base (cmdlet)
        {
        }
        
        internal override void Execute()
        {
            NewUIAWizardCommand cmdlet =
                (NewUIAWizardCommand)this.Cmdlet;
            
            WizardHelper.CreateWizard(cmdlet);
        }
    }
}
