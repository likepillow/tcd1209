using System;
using System.IO;
using CyUSB;

// Binary RPC on redirected stdin/stdout. No firmware, reset or configuration
// requests. One caller serializes reads and writes; failed OUT is never retried.
public static class CypressTransport {
    public static void Run() {
        using (USBDeviceList devices = new USBDeviceList(1)) {
            CyUSBDevice device = null;
            for (int i=0; i<devices.Count; i++) {
                CyUSBDevice candidate = devices[i] as CyUSBDevice;
                if (candidate != null && candidate.VendorID==0x04b4 && candidate.ProductID==0x00f1) {
                    if (device != null) throw new IOException("Multiple matching FX2 devices");
                    device=candidate;
                }
            }
            if (device==null || !device.bHighSpeed || device.bSuperSpeed)
                throw new IOException("Expected one high-speed FX2 04B4:00F1");
            CyUSBEndPoint input=null, output=null;
            foreach (CyUSBEndPoint endpoint in device.EndPoints) {
                if(endpoint.Address==0x86) input=endpoint;
                if(endpoint.Address==0x02) output=endpoint;
            }
            if(input==null || output==null || input.Attributes!=2 || output.Attributes!=2 ||
               input.MaxPktSize!=512 || output.MaxPktSize!=512)
                throw new IOException("Unexpected bulk endpoint layout");
            input.TimeOut=200; output.TimeOut=2000;
            BinaryReader reader=new BinaryReader(Console.OpenStandardInput());
            BinaryWriter writer=new BinaryWriter(Console.OpenStandardOutput());
            writer.Write(new byte[]{70,88,50,50});writer.Flush(); // FX22: detailed status
            while(true) {
                int op;
                try { op=reader.ReadByte(); } catch(EndOfStreamException) { break; }
                if(op==0) break;
                int length=reader.ReadInt32();
                if(length<1 || length>65536 || (op!=1 && op!=2)) throw new IOException("Invalid transport request");
                byte[] buffer=op==1 ? new byte[length] : reader.ReadBytes(length);
                if(buffer.Length!=length) throw new EndOfStreamException();
                CyUSBEndPoint endpoint=op==1 ? input : output;
                int transferred=length;
                var elapsed=System.Diagnostics.Stopwatch.StartNew();
                bool ok=endpoint.XferData(ref buffer,ref transferred);
                elapsed.Stop();
                if(transferred<0 || transferred>length) throw new IOException("Invalid transfer length");
                writer.Write(ok ? (byte)0 : (byte)1);
                writer.Write(transferred);
                writer.Write((int)endpoint.LastError);
                writer.Write(unchecked((uint)endpoint.NtStatus));
                writer.Write(unchecked((uint)endpoint.UsbdStatus));
                writer.Write((uint)Math.Min(elapsed.ElapsedMilliseconds,uint.MaxValue));
                if(op==1 && transferred>0) writer.Write(buffer,0,transferred);
                writer.Flush();
            }
        }
    }
}
